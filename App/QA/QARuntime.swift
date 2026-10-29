#if DEBUG
import Commit
import Foundation
import Indexer
import Library
import Photos
import Squish
import SquishBridge
import Store
import Synchronization
import os

/// DEBUG-only device QA (docs/qa/device-2026-10-23.md). Release builds compile none of this folder except the no-op
/// `qaDebugOverlay()`.
///
/// Launch arguments:
/// - `-QAAlbum <title>`: the library scope is that one user album (Library fetches, so the indexer, Squish, Duplicates,
///   swipefiles and the commit planner see nothing else), and every delete, album move, squish and copy removal is
///   re-checked against the album right before it happens (`QAAlbumGate`). Implies `-QAMetrics`. The run keeps its own
///   database, vector index and onboarding flag (`storageBase`, `defaults`): an album-scoped sync would otherwise mark
///   the rest of the real library deleted and purge its vectors, and `-UITestResetState` resets only the QA copy.
/// - `-QAMetrics`: appends identifier-free JSON lines to `Documents/qa/metrics.jsonl`. Without `-QAAlbum` the run is
///   read-only: every change is refused (`QAReadOnlyGate`).
/// - `-QAPauseBeforeSquishDelete`: before the squish delete prompt, wait for the overlay's "Continue" button (manual
///   QA: change an original between prepare and commit).
/// - `-QAFakeAvailableBytes <n>`: the squish flow sees `n` bytes free (insufficient-space check).
/// - `-QASquishStartEmpty`: Squish starts with nothing selected, so a test ticks only what it means to squish (a video
///   below the fold is otherwise selected when its probe finishes, after the test has set the selection).
/// - `-QASearchBench`: once the model is attached and indexing is idle, time searches over the whole index
///   (`QASearchBench`).
/// - `-QAThumbProbe`: 90 s after launch, measure which thumbnail sizes the library answers locally (network off) and
///   how long Roll's Vision signals take per image. Read-only.
/// - `-QAExhaustFreeQuota`: uses up Roll's own free-quota counter (to test the paywall unlock). Library untouched.
/// - `-QADolbyVisionExperiment`: with `-QAAlbum`, export each Dolby Vision clip in the album to a temporary file with
///   the HEVC presets and record what the output keeps. Never writes to the library.
/// - `-QARestock`: with `-QAAlbum`, import the files in `Documents/qa-restock/` (`scripts/qa_restock.sh`) into the
///   album, after taking out as few iCloud-only items as needed to stay within 40 (`QARestock`). Ignored otherwise.
final class QARuntime: Sendable {
  static let shared: QARuntime? = QARuntime(arguments: ProcessInfo.processInfo.arguments)

  let albumTitle: String?
  let pausesBeforeSquishDelete: Bool
  let fakeAvailableBytes: Int64?
  let squishStartsEmpty: Bool
  let runsDolbyVisionExperiment: Bool
  /// `-QARestock` together with a usable `-QAAlbum` title.
  let restocks: Bool
  let log: QAEventLog
  let counters = QACounters()

  /// `-QAAlbum` with an empty or missing title (the next argument is absent, empty or another flag).
  let albumTitleMissing: Bool
  /// Any `-QAAlbum`, with or without a usable title, so a mistyped title can't reach (or reset) the real database.
  let keepsOwnStore: Bool

  /// Any `-QAAlbum` or `-QAMetrics` makes a runtime. `-QAAlbum` without a usable title never falls back to the
  /// normal, ungated app: the run is read-only (every change refused) and the problem is logged and shown.
  init?(arguments: [String]) {
    func value(after flag: String) -> String? {
      guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
      return arguments[i + 1]
    }
    let wantsAlbum = arguments.contains("-QAAlbum")
    // Any -QA* argument turns QA mode on (read-only unless -QAAlbum names an album).
    guard wantsAlbum || arguments.contains(where: { $0.hasPrefix("-QA") }) else { return nil }
    let title = value(after: "-QAAlbum").flatMap { raw -> String? in
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty || trimmed.hasPrefix("-") ? nil : raw
    }
    albumTitle = title
    albumTitleMissing = wantsAlbum && title == nil
    keepsOwnStore = wantsAlbum
    pausesBeforeSquishDelete = arguments.contains("-QAPauseBeforeSquishDelete")
    fakeAvailableBytes = value(after: "-QAFakeAvailableBytes").flatMap(Int64.init)
    squishStartsEmpty = arguments.contains("-QASquishStartEmpty")
    runsDolbyVisionExperiment = arguments.contains("-QADolbyVisionExperiment")
    restocks = arguments.contains("-QARestock") && title != nil
    log = QAEventLog()
    if arguments.contains("-QARestock"), title == nil {
      log.write("qa_config_error", ["problem": .string("-QARestock without a QA album"), "mode": .string("no restock")])
    }
    if albumTitleMissing {
      QARuntime.logger.fault("-QAAlbum was given without an album title: this QA run is read-only, every change is refused")
      log.write("qa_config_error", ["problem": .string("-QAAlbum without a title"), "mode": .string("read-only")])
    }
  }

  static let logger = Logger(subsystem: "com.delavalom.roll", category: "qa")

  var isReadOnly: Bool { albumTitle == nil }

  /// `Application Support/qa` on `-QAAlbum` runs: the base for `AppDatabase.defaultURL(in:)` and
  /// `VectorStore.defaultURL(in:)` (`qa/Roll/roll.sqlite`, `qa/Roll/Index/`). Nil means the real ones.
  var storageBase: URL? {
    keepsOwnStore ? URL.applicationSupportDirectory.appending(path: "qa", directoryHint: .isDirectory) : nil
  }

  /// The onboarding flag and settings of `-QAAlbum` runs, apart from the real app's. Nil means `.standard`.
  var defaults: UserDefaults? { keepsOwnStore ? UserDefaults(suiteName: "com.delavalom.roll.qa") : nil }

  /// Checked before every change: the QA album, or refuse-all on a read-only run. Refusals are logged.
  var gate: any QAScopeGate {
    let inner: any QAScopeGate = albumTitle.map { PhotoKitQAAlbum.gate(title: $0) } ?? QAReadOnlyGate()
    return LoggingGate(inner: inner, log: log)
  }

  var library: any LibrarySource { QALibrary(albumTitle: albumTitle, counters: counters) }

  func squishFlow(journal: any SquishJournal, allowNetwork: Bool, background: any BackgroundExecution) -> ReplaceFlow? {
    guard let fakeAvailableBytes else { return nil }
    log.write("qa_fake_space", ["availableBytes": .int(fakeAvailableBytes)])
    return ReplaceFlow.qa(journal: journal, allowNetwork: allowNetwork, background: background,
                          availableBytes: fakeAvailableBytes)
  }

  func scoped(_ runner: ReplaceFlowRunner) -> ReplaceFlowRunner {
    let log = log, pauses = pausesBeforeSquishDelete
    return runner.qaScoped(gate: gate, hooks: QASquishHooks(
      prepared: { QASquishAudit.prepared($0, log: log) },
      beforeCommitDeletes: { count in
        log.write("squish_before_delete", ["originals": .int(count), "paused": .bool(pauses)])
        if pauses { await QAPause.shared.wait(originals: count) }
      },
      committed: { QASquishAudit.committed($0, log: log) }))
  }
}

/// Logs each gate decision (operation, count, refused or not), never the ids.
private struct LoggingGate: QAScopeGate {
  let inner: any QAScopeGate
  let log: QAEventLog

  func check(_ ids: [String], for operation: QAOperation) async throws {
    do {
      try await inner.check(ids, for: operation)
      if !ids.isEmpty { log.write("qa_gate", ["operation": .string(operation.rawValue), "count": .int(ids.count), "allowed": .bool(true)]) }
    } catch {
      log.write("qa_gate", ["operation": .string(operation.rawValue), "count": .int(ids.count), "allowed": .bool(false),
                            "refusal": .string(String(describing: error))])
      throw error
    }
  }
}

// MARK: - Library

/// Thumbnail and frame outcomes, for the indexer's batch metrics (how many needed iCloud or failed).
final class QACounters: Sendable {
  struct Counts: Sendable, Equatable {
    var image = 0, preview = 0, inCloud = 0, failed = 0, cancelled = 0
    var total: Int { image + preview + inCloud + failed + cancelled }
    static func - (a: Counts, b: Counts) -> Counts {
      Counts(image: a.image - b.image, preview: a.preview - b.preview, inCloud: a.inCloud - b.inCloud,
             failed: a.failed - b.failed,
             cancelled: a.cancelled - b.cancelled)
    }
  }

  private let counts = Mutex(Counts())
  var current: Counts { counts.withLock { $0 } }

  func add(_ result: ThumbnailResult) {
    counts.withLock {
      switch result {
      case .image: $0.image += 1
      case .preview: $0.preview += 1
      case .inCloud: $0.inCloud += 1
      case .failed: $0.failed += 1
      case .cancelled: $0.cancelled += 1
      }
    }
  }
}

/// `PhotoLibrary`, scoped to the QA album when there is one, counting thumbnail outcomes.
struct QALibrary: LibrarySource {
  let albumTitle: String?
  let counters: QACounters
  private let base = PhotoLibrary()

  init(albumTitle: String?, counters: QACounters) {
    self.albumTitle = albumTitle; self.counters = counters
  }

  /// The album's ids now; nil without an album. A missing or ambiguous album is an empty scope.
  private func members() -> Set<String>? {
    guard let albumTitle else { return nil }
    if case .found(let ids) = PhotoKitQAAlbum.lookup(title: albumTitle) { return ids }
    return []
  }

  func fetchAll() async -> [AssetSnapshot] {
    let start = ContinuousClock.now
    defer { QARuntime.shared?.log.write("sync_read", ["step": .string("fetchAll"), "ms": .int(Self.ms(since: start))]) }
    guard let members = members() else { return await base.fetchAll() }
    return base.snapshots(ids: Array(members)).sorted { ($0.created ?? 0, $0.id) > ($1.created ?? 0, $1.id) }
  }

  func snapshots(ids: [String]) async -> [AssetSnapshot] {
    guard let members = members() else { return base.snapshots(ids: ids) }
    return base.snapshots(ids: ids.filter(members.contains))
  }

  func utis(for ids: [String]) async -> [String: String] {
    let start = ContinuousClock.now
    let utis = await base.utis(for: ids)
    QARuntime.shared?.log.write("sync_read", ["step": .string("utis"), "ids": .int(ids.count), "ms": .int(Self.ms(since: start)),
                                              "thermal": .int(ProcessInfo.processInfo.thermalState.rawValue)])
    return utis
  }

  static func ms(since start: ContinuousClock.Instant) -> Int {
    let d = ContinuousClock.now - start
    return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
  }

  func thumbnails(ids: [String], side: Int, allowNetwork: Bool) async -> [String: ThumbnailResult] {
    let results = await base.thumbnails(ids: ids, side: side, allowNetwork: allowNetwork)
    for result in results.values { counters.add(result) }
    return results
  }

  func videoFrame(id: String, at fraction: Double, side: Int, allowNetwork: Bool) async -> ThumbnailResult {
    let result = await base.videoFrame(id: id, at: fraction, side: side, allowNetwork: allowNetwork)
    counters.add(result)
    return result
  }
}

// MARK: - Pause before the squish delete (manual QA)

@Observable @MainActor
final class QAPause {
  static let shared = QAPause()

  private(set) var waitingOriginals: Int?
  /// One continuation per waiting caller; "Continue" resumes them all.
  @ObservationIgnored private var continuations: [CheckedContinuation<Void, Never>] = []

  nonisolated func wait(originals: Int) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      Task { @MainActor in
        self.continuations.append(c)
        self.waitingOriginals = (self.waitingOriginals ?? 0) + originals
      }
    }
  }

  func resume() {
    waitingOriginals = nil
    let waiting = continuations
    continuations = []
    for c in waiting { c.resume() }
  }
}

// MARK: - Squish audit (identifier-free)

enum QASquishAudit {
  static func prepared(_ report: PrepareReport, log: QAEventLog) {
    for p in report.prepared {
      let o = p.verifiedOriginal, c = p.verifiedCopy
      log.write("squish_prepared", [
        "kind": .string(o.isVideo ? "video" : "photo"),
        "originalBytes": .int(p.originalBytes), "newBytes": .int(p.newBytes), "savedBytes": .int(p.estimatedSavings),
        "savedFraction": .double(p.originalBytes > 0 ? Double(p.estimatedSavings) / Double(p.originalBytes) : 0),
        "keep4K": .bool(p.keep4K),
        "original": .string("\(o.pixelWidth)x\(o.pixelHeight)"), "copy": .string("\(c.pixelWidth)x\(c.pixelHeight)"),
        "durationDelta": .double(abs(c.duration - o.duration)),
      ].merging(metadata(original: o, copy: c)) { a, _ in a })
    }
    for f in report.failures {
      log.write("squish_failed", ["reason": .string(reason(f.error))])
    }
    if report.cancelled { log.write("squish_cancelled", [:]) }
  }

  static func committed(_ result: Result<SquishCommitResult, ReplaceError>, log: QAEventLog) {
    switch result {
    case .failure(let error):
      log.write("squish_commit", ["outcome": .string(reason(error))])
    case .success(let r):
      log.write("squish_commit", [
        "outcome": .string("done"), "deleted": .int(r.deleted.count), "skipped": .int(r.skipped.count),
        "skipReasons": .string(r.skipped.map { "\($0.reason)" }.joined(separator: "; ")),
        "estimatedSavings": .int(r.estimatedSavings), "recentlyDeletedPending": .bool(r.recentlyDeletedPending),
      ])
      // The copies as the library has them now that their originals are gone: did the metadata survive?
      for p in r.deleted {
        let after = PhotoKitFingerprint.read(p.newAssetID)
        var fields: [String: QAEventLog.Value] = ["copyFound": .bool(after != nil), "kind": .string(p.verifiedOriginal.isVideo ? "video" : "photo"),
                                                  "savedBytes": .int(p.estimatedSavings)]
        if let after { fields.merge(metadata(original: p.verifiedOriginal, copy: after)) { a, _ in a } }
        log.write("squish_copy_after_delete", fields)
      }
    }
  }

  /// Date, location, favorite, hidden and album membership: same or not (no values).
  static func metadata(original o: AssetFingerprint, copy c: AssetFingerprint) -> [String: QAEventLog.Value] {
    let sameDate = switch (o.creationDate, c.creationDate) {
    case (nil, nil): true
    case let (a?, b?): abs(a.timeIntervalSince(b)) <= 1
    default: false
    }
    let sameLocation = switch (o.latitude, o.longitude, c.latitude, c.longitude) {
    case (nil, nil, nil, nil): true
    case let (a?, b?, x?, y?): abs(a - x) <= 1e-4 && abs(b - y) <= 1e-4
    default: false
    }
    return [
      "dateKept": .bool(sameDate), "hadLocation": .bool(o.latitude != nil), "locationKept": .bool(sameLocation),
      "favorite": .bool(o.isFavorite), "favoriteKept": .bool(o.isFavorite == c.isFavorite),
      "hiddenKept": .bool(o.isHidden == c.isHidden), "albums": .int(o.albumIDs.count),
      "albumsKept": .bool(o.albumIDs.isSubset(of: c.albumIDs)),
    ]
  }

  /// The error's kind and fixed reason text; never ids, file names or paths.
  static func reason(_ error: any Error) -> String {
    if let qa = error as? QAScopeViolation { return qa.description }
    guard let e = error as? ReplaceError else { return String(describing: type(of: error)) }
    switch e {
    case .ineligible(let why): return "ineligible(\(why))"
    case .squish(let s):
      switch s {
      case .ineligible(let why): return "squish.ineligible(\(why))"
      case .exportFailed(let u): return "squish.exportFailed(\((u as NSError).domain) \((u as NSError).code))"
      default: return "squish.\(String(describing: s).prefix(while: { $0 != "(" }))"
      }
    case .verificationFailed(let why, _): return "verificationFailed(\(why))"
    case .insufficientSpace(let required, let available): return "insufficientSpace(required \(required), available \(available))"
    case .resourceExportFailed(let u): return "resourceExportFailed(\((u as NSError).domain) \((u as NSError).code))"
    case .createFailed(let u): return "createFailed(\((u as NSError).domain) \((u as NSError).code))"
    case .deleteFailed(let u): return "deleteFailed(\((u as NSError).domain) \((u as NSError).code))"
    default: return "\(e)"
    }
  }
}

/// The same fingerprint fields the squish flow verifies, read from PhotoKit for a copy (read-only).
enum PhotoKitFingerprint {
  static func read(_ id: String) -> AssetFingerprint? {
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else { return nil }
    var albums = Set<String>()
    PHAssetCollection.fetchAssetCollectionsContaining(a, with: .album, options: nil).enumerateObjects { c, _, _ in
      if c.assetCollectionSubtype == .albumRegular, c.canPerform(.addContent) { albums.insert(c.localIdentifier) }
    }
    return AssetFingerprint(isVideo: a.mediaType == .video, duration: a.duration, pixelWidth: a.pixelWidth,
                            pixelHeight: a.pixelHeight, creationDate: a.creationDate, modificationDate: a.modificationDate,
                            isFavorite: a.isFavorite, isHidden: a.isHidden, latitude: a.location?.coordinate.latitude,
                            longitude: a.location?.coordinate.longitude, albumIDs: albums)
  }
}

// MARK: - The log

private struct QAPayloadLine<P: Encodable>: Encodable {
  let event: String
  let t: Double
  let up: Double
  let data: P
}

/// Appends one JSON object per line to `Documents/qa/metrics.jsonl`. Values are numbers, booleans and fixed strings;
/// callers never pass identifiers, file names or photo content.
final class QAEventLog: Sendable {
  enum Value: Sendable, Encodable {
    case int(Int64), double(Double), bool(Bool), string(String)
    static func int(_ v: Int) -> Value { .int(Int64(v)) }

    func encode(to encoder: any Encoder) throws {
      var c = encoder.singleValueContainer()
      switch self {
      case .int(let v): try c.encode(v)
      case .double(let v): try c.encode(v.isFinite ? v : 0)
      case .bool(let v): try c.encode(v)
      case .string(let v): try c.encode(v)
      }
    }
  }

  static let directory: URL = URL.documentsDirectory.appending(path: "qa", directoryHint: .isDirectory)
  static let url = directory.appending(path: "metrics.jsonl")

  private let handle = Mutex<FileHandle?>(nil)
  private let start = ContinuousClock.now

  init() {
    try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: Self.url.path) {
      FileManager.default.createFile(atPath: Self.url.path, contents: nil)
    }
    let h = try? FileHandle(forWritingTo: Self.url)
    _ = try? h?.seekToEnd()
    handle.withLock { $0 = h }
  }

  var uptime: Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
  }

  func write(_ event: String, _ fields: [String: Value]) {
    var all = fields
    all["event"] = .string(event)
    all["t"] = .double(Date().timeIntervalSince1970)
    all["up"] = .double((uptime * 10).rounded() / 10)
    write(line: all)
  }

  /// Any encodable payload under `data` (inventory items, export results).
  func write<T: Encodable>(_ event: String, payload: T) {
    append(try? Self.encoder.encode(QAPayloadLine(event: event, t: Date().timeIntervalSince1970, up: uptime, data: payload)))
  }

  private func write(line: [String: Value]) { append(try? Self.encoder.encode(line)) }

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
  }()

  private func append(_ data: Data?) {
    guard var data else { return }
    data.append(0x0A)
    handle.withLock { try? $0?.write(contentsOf: data) }
  }
}
#endif
