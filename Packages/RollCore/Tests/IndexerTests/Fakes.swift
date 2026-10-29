import CoreGraphics
import Embedding
import Foundation
import GRDB
import Library
import Signals
import Store
import Synchronization
import Testing
@testable import Indexer

/// Ordered record of the writes the Indexer makes, shared by the recording repo and vector sink.
final class EventLog: Sendable {
  private let events = Mutex<[String]>([])
  func append(_ event: String) { events.withLock { $0.append(event) } }
  var all: [String] { events.withLock { $0 } }
  func clear() { events.withLock { $0.removeAll() } }
  var signalCommits: [String] { all.filter { $0.hasPrefix("signals:") } }
  /// Vector-file and flag writes, in order (no signal commits, failures or reserves).
  var vectorEvents: [String] {
    all.filter { e in ["upsert:", "save", "embedded:", "remove:", "unflag:"].contains { e.hasPrefix($0) } }
  }
}

/// The real `Repositories`, with commit calls logged.
struct RecordingRepo: IndexRepository {
  let base: Repositories
  let log: EventLog

  func upsertAssets(_ records: [AssetRecord]) async throws { try await base.upsertAssets(records) }
  func assetRefs(ids: [String]?) async throws -> [AssetRef] { try await base.assetRefs(ids: ids) }
  func markDeleted(_ ids: [String], at date: Date) async throws { try await base.markDeleted(ids, at: date) }
  func pendingAssetIds(includingEmbedding: Bool, includingCloudOnly: Bool) async throws -> [String] {
    try await base.pendingAssetIds(includingEmbedding: includingEmbedding, includingCloudOnly: includingCloudOnly)
  }
  func pendingAssetCount(includingEmbedding: Bool, includingCloudOnly: Bool) async throws -> Int {
    try await base.pendingAssetCount(includingEmbedding: includingEmbedding, includingCloudOnly: includingCloudOnly)
  }
  func recordFailedAttempts(ids: [String]) async throws {
    log.append("failed:\(ids.count)")
    try await base.recordFailedAttempts(ids: ids)
  }
  func clearEmbedded(ids: [String]) async throws -> Int {
    log.append("unflag:\(ids.count)")
    return try await base.clearEmbedded(ids: ids)
  }
  func deletedEmbeddedIds() async throws -> [String] { try await base.deletedEmbeddedIds() }
  func resetForContentChange(ids: [String]) async throws -> Int {
    log.append("reset:\(ids.count)")
    return try await base.resetForContentChange(ids: ids)
  }
  func assets(ids: [String]) async throws -> [AssetRecord] { try await base.assets(ids: ids) }
  func previewAssetIds() async throws -> [String] { try await base.previewAssetIds() }
  func typeLookupCandidates(minPixels: Int, excludingSubtypes: Int, limit: Int) async throws -> [String] {
    try await base.typeLookupCandidates(minPixels: minPixels, excludingSubtypes: excludingSubtypes, limit: limit)
  }
  func updateTypes(_ updates: [(id: String, uti: String, estBytes: Int64)]) async throws {
    try await base.updateTypes(updates)
  }
  func commitSignals(_ updates: [SignalFields]) async throws {
    log.append("signals:\(updates.count)")
    try await base.commitSignals(updates)
  }
  func markEmbedded(ids: [String]) async throws {
    log.append("embedded:\(ids.count)")
    try await base.markEmbedded(ids: ids)
  }
}

/// The real `VectorStore`, with batch upserts and saves logged.
struct RecordingVectors: VectorSink {
  let base: VectorStore
  let log: EventLog

  var dimensions: Int { base.dimensions }
  var revision: String { base.revision }
  var count: Int { get async { await base.count } }
  func reserve(_ expectedCount: Int) async {
    log.append("reserve:\(expectedCount)")
    await base.reserve(expectedCount)
  }
  func upsert(_ batch: [(id: String, vector: [Float])]) async throws {
    log.append("upsert:\(batch.count)")
    try await base.upsert(batch)
  }
  func remove(ids: [String]) async throws {
    log.append("remove:\(ids.count)")
    try await base.remove(ids: ids)
  }
  func save() async throws {
    log.append("save")
    try await base.save()
  }
}

/// A photo library in memory. Every 10th asset is a video unless `videoEvery` says otherwise.
final class FakeLibrary: LibrarySource {
  enum Behavior: Sendable {
    case image
    /// Only in iCloud: `.inCloud` without network, an image with it.
    case inCloud
    /// Only in iCloud, with a local preview: `.preview` without network, an image with it.
    case preview
    /// Only in iCloud and the download fails: `.preview` even with network.
    case previewOnly
    case failedOnce
    case failedAlways
    case cancelled
    /// Blocks until the calling task is cancelled, then reports `.cancelled`.
    case hang
  }

  struct State {
    var assets: [AssetSnapshot]
    var utiTable: [String: String] = [:]
    var behavior: [String: Behavior] = [:]
    var failedAlready: Set<String> = []
    var fetchAllCalls = 0
    var snapshotCalls: [[String]] = []
    var utiCalls: [[String]] = []
    var thumbnailIds: [String] = []
    var thumbnailCallSizes: [Int] = []
    /// The `side` of each thumbnail and video-frame request.
    var requestedSides: [Int] = []
    var hangEntered = false
    var videoFrameIds: [String] = []
    var networkRequests: [String] = []
  }

  let state: Mutex<State>

  init(count: Int, videoEvery: Int? = 10) {
    state = Mutex(State(assets: (0..<count).map { Self.snapshot($0, videoEvery: videoEvery) }))
  }

  init(assets: [AssetSnapshot]) {
    state = Mutex(State(assets: assets))
  }

  static func id(_ i: Int) -> String { String(format: "a%05d", i) }

  /// Newest first: a00000 is the newest.
  static func snapshot(_ i: Int) -> AssetSnapshot { snapshot(i, videoEvery: 10) }

  static func snapshot(_ i: Int, videoEvery: Int?) -> AssetSnapshot {
    let video = videoEvery.map { i % $0 == $0 - 1 } ?? false
    return AssetSnapshot(id: id(i), mediaType: video ? MediaKind.video : MediaKind.image, created: Double(1_000_000 - i),
                         pixelW: 4000, pixelH: 3000, duration: video ? 10 : 0)
  }

  func set(_ behavior: Behavior, for ids: [String]) {
    state.withLock { s in for id in ids { s.behavior[id] = behavior } }
  }

  func fetchAll() -> [AssetSnapshot] {
    state.withLock { s in s.fetchAllCalls += 1; return s.assets }
  }

  func snapshots(ids: [String]) -> [AssetSnapshot] {
    state.withLock { s in
      s.snapshotCalls.append(ids)
      let byId = Dictionary(uniqueKeysWithValues: s.assets.map { ($0.id, $0) })
      return ids.compactMap { byId[$0] }
    }
  }

  func utis(for ids: [String]) -> [String: String] {
    state.withLock { s in
      s.utiCalls.append(ids)
      return s.utiTable.filter { ids.contains($0.key) }
    }
  }

  func thumbnails(ids: [String], side: Int, allowNetwork: Bool) async -> [String: ThumbnailResult] {
    state.withLock { $0.thumbnailCallSizes.append(ids.count); $0.requestedSides.append(side) }
    var out: [String: ThumbnailResult] = [:]
    for id in ids {
      out[id] = await result(for: id, allowNetwork: allowNetwork) { $0.thumbnailIds.append(id) }
    }
    return out
  }

  func videoFrame(id: String, at fraction: Double, side: Int, allowNetwork: Bool) async -> ThumbnailResult {
    state.withLock { $0.requestedSides.append(side) }
    return await result(for: id, allowNetwork: allowNetwork) { $0.videoFrameIds.append(id) }
  }

  private func result(for id: String, allowNetwork: Bool, record: (inout State) -> Void) async -> ThumbnailResult {
    let behavior: Behavior = state.withLock { s in
      record(&s)
      if allowNetwork { s.networkRequests.append(id) }
      var b = s.behavior[id] ?? .image
      if b == .failedOnce {
        b = s.failedAlready.insert(id).inserted ? .failedOnce : .image
      }
      return b
    }
    switch behavior {
    case .image: return .image(FakeImage.make(seed: id.hashValue))
    case .inCloud: return allowNetwork ? .image(FakeImage.make(seed: 1)) : .inCloud
    case .preview: return allowNetwork ? .image(FakeImage.make(seed: 2)) : .preview(FakeImage.make(seed: 3))
    case .previewOnly: return .preview(FakeImage.make(seed: 3))
    case .failedOnce, .failedAlways: return .failed
    case .cancelled: return .cancelled
    case .hang:
      state.withLock { $0.hangEntered = true }
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
      return .cancelled
    }
  }
}

enum FakeImage {
  static func make(seed: Int) -> CGImage {
    var bytes = (0..<64).map { UInt8(truncatingIfNeeded: seed &+ $0 &* 37) }
    return bytes.withUnsafeMutableBytes {
      CGContext(data: $0.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
    }
  }
}

/// Fixed signals. `onExtract` runs inside each call with the running count (1-based); like the real
/// extractor, a call that finds its task cancelled throws.
final class FakeSignals: SignalSource {
  static let output = AssetSignals(blur: 1.5, aesthetic: 0.25, isUtility: false, sensitive: nil, phash: 42,
                                   featurePrint: Data([1, 2, 3]))
  private let counts = Mutex((extract: 0, refresh: 0))
  let onExtract = Mutex<(@Sendable (Int) -> Void)?>(nil)
  /// Awaited inside each call (after `onExtract`), so a test can suspend the pipeline mid-asset.
  let onExtractAsync = Mutex<(@Sendable (Int) async -> Void)?>(nil)

  var extractCalls: Int { counts.withLock { $0.extract } }
  var refreshCalls: Int { counts.withLock { $0.refresh } }

  func refreshPolicy() { counts.withLock { $0.refresh += 1 } }

  func extract(_ image: CGImage) async throws(CancellationError) -> AssetSignals {
    let n = counts.withLock { c in c.extract += 1; return c.extract }
    onExtract.withLock { $0 }?(n)
    if let hook = onExtractAsync.withLock({ $0 }) { await hook(n) }
    if Task.isCancelled { throw CancellationError() }
    return Self.output
  }
}

/// A database, vector file, fake library, signals and thermal state, with recording wrappers.
struct Harness {
  static let embedder = StubEmbedder(dimensions: 8)

  let db: AppDatabase
  let repo: Repositories
  let log = EventLog()
  let library: FakeLibrary
  let signals = FakeSignals()
  let thermal: FakeThermal
  let store: VectorStore

  var recordingRepo: RecordingRepo { RecordingRepo(base: repo, log: log) }
  var vectors: RecordingVectors { RecordingVectors(base: store, log: log) }

  /// Save debounce off unless a test sets `minimumSaveInterval`: every run ends with a vector flush.
  static var testConfig: IndexerConfig {
    var config = IndexerConfig()
    config.minimumSaveInterval = .zero
    return config
  }

  func indexer(embedder: Bool = true, config: IndexerConfig = Harness.testConfig, pollInterval: Duration = .milliseconds(2),
               vectors sink: (any VectorSink)? = nil, library source: (any LibrarySource)? = nil) throws -> Indexer {
    try Indexer(library: source ?? library, signals: signals, repo: recordingRepo,
                thermal: ThermalGate(provider: thermal, pollInterval: pollInterval),
                embedder: embedder ? Self.embedder : nil, vectors: embedder ? (sink ?? vectors) : sink, config: config)
  }

  /// `openVectors` for `setEmbedder` that hands back this harness's store.
  var openSameStore: @Sendable (String, Int) async throws -> any VectorSink {
    let vectors = vectors
    return { _, _ in vectors }
  }

  func count(_ condition: String) async throws -> Int {
    try await db.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE \(condition)") ?? 0 }
  }

  /// A fresh harness in a temp directory, removed afterwards.
  static func with<T>(library: FakeLibrary, hotReads: Int = 0, _ body: (Harness) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-indexer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try AppDatabase.inMemory()
    let store = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: embedder.dimensions,
                                      revision: embedder.revision, database: db)
    let harness = Harness(db: db, repo: Repositories(db), library: library, thermal: FakeThermal(hotReads: hotReads),
                          store: store)
    return try await body(harness)
  }

  static func with<T>(count: Int, hotReads: Int = 0, videoEvery: Int? = 10, _ body: (Harness) async throws -> T)
    async throws -> T {
    try await with(library: FakeLibrary(count: count, videoEvery: videoEvery), hotReads: hotReads, body)
  }

  /// Polls `condition` every millisecond for up to 4 s.
  static func waitUntil(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<4000 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting")
  }
}

/// Wraps the real store: `save()` fails while `failSaves > 0` (each failure decrements it), and blocks
/// while `gate` is closed (setting `saveEntered`).
final class ControlledSink: VectorSink {
  let base: VectorStore
  let log: EventLog
  let failSaves = Mutex(0)
  let gateOpen = Mutex(true)
  let saveEntered = Mutex(false)

  init(base: VectorStore, log: EventLog) { self.base = base; self.log = log }

  var dimensions: Int { base.dimensions }
  var revision: String { base.revision }
  var count: Int { get async { await base.count } }
  func reserve(_ expectedCount: Int) async { await base.reserve(expectedCount) }
  func upsert(_ batch: [(id: String, vector: [Float])]) async throws {
    log.append("upsert:\(batch.count)")
    try await base.upsert(batch)
  }
  func remove(ids: [String]) async throws { try await base.remove(ids: ids) }
  func save() async throws {
    saveEntered.withLock { $0 = true }
    while !gateOpen.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
    if failSaves.withLock({ n in defer { if n > 0 { n -= 1 } }; return n > 0 }) {
      log.append("save-failed")
      throw CocoaError(.fileWriteOutOfSpace)
    }
    log.append("save")
    try await base.save()
  }
}

/// StubEmbedder that throws on the listed call numbers and returns a wrong-length vector on others.
final class FlakyEmbedder: Embedder {
  let base = Harness.embedder
  let throwOn: Set<Int>
  let wrongLengthOn: Set<Int>
  private let calls = Mutex(0)

  init(throwOn: Set<Int> = [], wrongLengthOn: Set<Int> = []) { self.throwOn = throwOn; self.wrongLengthOn = wrongLengthOn }

  var dimensions: Int { base.dimensions }
  var revision: String { base.revision }
  func embed(image: CGImage) async throws -> [Float] {
    let n = calls.withLock { c in c += 1; return c }
    if throwOn.contains(n) { throw CocoaError(.featureUnsupported) }
    if wrongLengthOn.contains(n) { return [1, 2, 3] }
    return try await base.embed(image: image)
  }
  func embed(query: String) async throws -> [Float] { try await base.embed(query: query) }
}
