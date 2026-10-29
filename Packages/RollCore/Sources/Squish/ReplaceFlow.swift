import Foundation
import Store
import Synchronization
#if canImport(Photos) && os(iOS)
import CoreLocation
import Photos
#endif

// This file and Commit/PhotoKitCommitter.swift are the only places allowed to make destructive PhotoKit calls.

// MARK: - Public model

public enum SquishPhase: Sendable, Equatable {
  case downloading, encoding, verifying, saving
}

public struct SquishProgress: Sendable, Equatable {
  public let assetID: String
  public let phase: SquishPhase
  /// 0...1 when the phase can tell (downloads), otherwise `nil`.
  public let fraction: Double?
}

/// Lets the app keep an item running briefly after it leaves the foreground (`UIApplication.beginBackgroundTask`)
/// without this package importing UIKit.
///
/// Contract for the adapter:
/// - `onExpiration` fires when the system is about to suspend the app. The adapter **must end the background task
///   inside its expiration handler** (UIKit kills the app otherwise), after calling `onExpiration`.
/// - `end` must be idempotent: the flow also calls it once the item is done, possibly after the adapter already ended it.
public protocol BackgroundExecution: Sendable {
  /// Returns a token for `end`, or `nil` when no background time could be requested.
  func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int?
  func end(_ token: Int)
}

public struct NoBackgroundExecution: BackgroundExecution {
  public init() {}
  public func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int? { nil }
  public func end(_ token: Int) {}
}

public struct SquishItem: Sendable, Equatable {
  public let assetID: String
  /// The library's size estimate; used for the free-space check before anything is exported.
  public let estimatedBytes: Int64
  public let keep4K: Bool

  public init(assetID: String, estimatedBytes: Int64, keep4K: Bool = false) {
    self.assetID = assetID; self.estimatedBytes = estimatedBytes; self.keep4K = keep4K
  }

  public init(_ plan: SquishPlanItem, keep4K: Bool = false) {
    self.init(assetID: plan.assetID, estimatedBytes: plan.estimatedBytes, keep4K: keep4K)
  }
}

/// A verified smaller copy that exists in the library next to its still-present original. Carries the library state
/// it was verified against, so `commitDeletes` can tell whether anything changed since.
public struct Prepared: Codable, Sendable, Equatable {
  public let assetID: String
  public let newAssetID: String
  /// Measured: size of the exported original and of the squished file.
  public let originalBytes: Int64
  public let newBytes: Int64
  public let keep4K: Bool
  public let verifiedOriginal: AssetFingerprint
  public let verifiedCopy: AssetFingerprint
  /// What deleting the original is expected to free. Not freed until Recently Deleted is emptied.
  public var estimatedSavings: Int64 { max(0, originalBytes - newBytes) }

  public init(assetID: String, newAssetID: String, originalBytes: Int64, newBytes: Int64, keep4K: Bool,
              verifiedOriginal: AssetFingerprint, verifiedCopy: AssetFingerprint) {
    self.assetID = assetID; self.newAssetID = newAssetID; self.originalBytes = originalBytes; self.newBytes = newBytes
    self.keep4K = keep4K; self.verifiedOriginal = verifiedOriginal; self.verifiedCopy = verifiedCopy
  }
}

public struct PrepareFailure: Sendable, Equatable {
  public let assetID: String
  public let error: ReplaceError
}

public struct PrepareReport: Sendable, Equatable {
  public var prepared: [Prepared] = []
  public var failures: [PrepareFailure] = []
  /// The run was cancelled (by the caller, or because background time expired). Items after the cancel were not attempted.
  public var cancelled = false

  /// What the confirm sheet must say cannot be carried over.
  public var transferLimitations: [String] { SquishLimitations.items }

  /// Copies left behind by failed verification; pass to `ReplaceFlow.discardCopies` to clean up.
  public var leftoverCopyIDs: [String] {
    failures.compactMap { if case let .verificationFailed(_, id?) = $0.error { id } else { nil } }
  }
}

public struct SkippedItem: Sendable, Equatable {
  public let prepared: Prepared
  public let reason: SkipReason
}

public struct SquishCommitResult: Sendable, Equatable {
  /// Items whose originals were handed to the library for deletion (what the fetch actually returned).
  public let deleted: [Prepared]
  /// Items left alone, with why: an original that changed since verification, a missing copy, and so on.
  public let skipped: [SkippedItem]
  public var estimatedSavings: Int64 { deleted.reduce(0) { $0 + $1.estimatedSavings } }
  /// `true` when something was deleted: it sits in Recently Deleted, so the space is only freed when that is emptied
  /// or after 30 days. UI copy: "Freed after Recently Deleted is emptied (or in 30 days)".
  public let recentlyDeletedPending: Bool
}

public enum ReplaceError: Error, Sendable, Equatable {
  case assetNotFound
  case ineligible(IneligibilityReason)
  /// The photo library is in limited-access (or denied) mode. Album membership and many assets are invisible there,
  /// so copying and deleting could silently lose data. Ask for full access.
  case needsFullAccess
  /// The original is in iCloud and downloads weren't allowed.
  case needsDownload
  case insufficientSpace(required: Int64, available: Int64)
  case resourceExportFailed(any Error)
  /// Encoding or its checks failed (`.notSmaller`, `.durationMismatch`, `.unsupported`, `.exportFailed`, ...).
  case squish(SquishError)
  case createFailed(any Error)
  /// The new asset didn't match the original. `newAssetId` is the leftover copy (if one should be cleaned up): delete it
  /// with `ReplaceFlow.discardCopy`. The original is untouched.
  case verificationFailed(reason: String, newAssetId: String?)
  /// The user tapped Don't Allow on the delete confirmation. Copies and originals all remain.
  case userDeclinedDelete
  case deleteFailed(any Error)
  case cancelled

  public static func == (lhs: ReplaceError, rhs: ReplaceError) -> Bool {
    switch (lhs, rhs) {
    case (.assetNotFound, .assetNotFound), (.needsFullAccess, .needsFullAccess), (.needsDownload, .needsDownload),
         (.userDeclinedDelete, .userDeclinedDelete), (.cancelled, .cancelled): true
    case let (.ineligible(a), .ineligible(b)): a == b
    case let (.insufficientSpace(a, b), .insufficientSpace(c, d)): a == c && b == d
    case let (.squish(a), .squish(b)): a == b
    case let (.verificationFailed(a, b), .verificationFailed(c, d)): a == c && b == d
    case let (.resourceExportFailed(a), .resourceExportFailed(b)), let (.createFailed(a), .createFailed(b)),
         let (.deleteFailed(a), .deleteFailed(b)): (a as NSError) == (b as NSError)
    default: false
    }
  }
}

public struct OrphanCopy: Sendable, Equatable {
  public let assetID: String
  public let newAssetID: String
}

/// What `ReplaceFlow.reconcile()` found after a crash, kill or relaunch.
public struct JournalReconciliation: Sendable, Equatable {
  /// Verified copies whose originals are still there: offer `retryDelete` (which re-checks everything) or discard.
  public var pending: [Prepared] = []
  /// Copies that exist but were never verified: list them for the user to discard.
  public var orphans: [OrphanCopy] = []
}

// MARK: - Journal

/// Durable record of each squish, written before the library is changed. `Repositories` conforms.
public protocol SquishJournal: Sendable {
  func begin(assetID: String, originalBytes: Int64, newBytes: Int64) async throws
  /// Synchronous: called inside the library's change block as soon as the placeholder id is known.
  func noteNewAsset(assetID: String, newAssetID: String) throws
  func setState(assetID: String, state: SquishJournalRecord.State, payload: Data?) async throws
  func entries(states: [SquishJournalRecord.State]) async throws -> [SquishJournalRecord]
}

extension Repositories: SquishJournal {
  public func begin(assetID: String, originalBytes: Int64, newBytes: Int64) async throws {
    try await journalBegin(assetID: assetID, originalBytes: originalBytes, newBytes: newBytes)
  }
  public func noteNewAsset(assetID: String, newAssetID: String) throws {
    try journalNoteNewAsset(assetID: assetID, newAssetID: newAssetID)
  }
  public func setState(assetID: String, state: SquishJournalRecord.State, payload: Data?) async throws {
    try await journalSetState(assetID: assetID, state: state, payload: payload)
  }
  public func entries(states: [SquishJournalRecord.State]) async throws -> [SquishJournalRecord] {
    try await journalEntries(states: states)
  }
}

// MARK: - Library seam (the only thing that touches PhotoKit)

enum LibraryAccessLevel: Sendable, Equatable { case full, limited, denied }

struct LibraryAsset: Sendable {
  var facts: AssetFacts
  var originalFilename: String
  /// The library's own (oriented) pixel size, which the exported file must decode at.
  var pixelWidth: Int
  var pixelHeight: Int
}

struct GuardedOutcome: Sendable, Equatable {
  var prepared: Prepared
  var skip: SkipReason?
}

protocol PhotoLibraryGateway: Sendable {
  var accessLevel: LibraryAccessLevel { get }
  func inspect(_ assetID: String) async throws -> LibraryAsset
  /// Writes the original into `directory` and returns its URL. Throws `ReplaceError.needsDownload` when the file is in
  /// iCloud and `allowNetwork` is false. Cancelling the task cancels the download.
  func exportOriginal(_ assetID: String, to directory: URL, allowNetwork: Bool,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL
  /// Creates a new asset from `file` (moving it) with the original's date, location, favorite, hidden state and
  /// album membership. `onPlaceholder` is called inside the change block with the new id, before the copy exists.
  /// Returns the new local identifier. If the original is gone, creates nothing and throws.
  func createCopy(of assetID: String, from file: URL, filename: String,
                  onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> String
  func fingerprint(_ assetID: String) async -> AssetFingerprint?
  /// The copy's stored resource, read back through the library.
  func readBack(_ assetID: String) async throws -> CopyReadBack
  /// One change request: for each item, re-reads both assets inside the change block, applies `CommitGuard`, and deletes
  /// only the originals that pass. Throws `ReplaceError.userDeclinedDelete` on a user cancel.
  func deleteGuarded(_ items: [Prepared]) async throws -> [GuardedOutcome]
  /// Deletes leftover copies in one change request.
  func delete(_ copyIDs: [String]) async throws
}

// MARK: - Flow

private final class Flag: Sendable {
  private let value = Mutex(false)
  var isSet: Bool { value.withLock { $0 } }
  func set() { value.withLock { $0 = true } }
}

private final class ErrorBox: Sendable {
  private let value = Mutex<(any Error)?>(nil)
  var error: (any Error)? { value.withLock { $0 } }
  func record(_ e: any Error) { value.withLock { if $0 == nil { $0 = e } } }
}

/// Replaces library assets with smaller, metadata-preserving copies, in two steps so the user sees one prompt:
///
/// 1. `prepare(items)` exports, squishes, creates the new asset and verifies it. Originals are never touched.
/// 2. `commitDeletes(prepared)` re-checks every pair inside the change block and deletes only originals that are still
///    exactly as verified, in one change request (the system confirmation).
///
/// Requires full photo-library access: in limited mode album membership can't be read, so everything throws
/// `ReplaceError.needsFullAccess`. Every squish is journaled (`SquishJournal`) so a crash can't lose a copy;
/// call `reconcile()` on launch. If the user declines the delete, everything remains: `retryDelete` or `discardCopies`.
///
/// PhotoKit writes can't be unit-tested here; see the device QA checklist in `docs/MILESTONES.md`.
public final class ReplaceFlow: Sendable {
  let gateway: any PhotoLibraryGateway
  let workspace: SquishWorkspace
  let space: SquishDiskSpace
  let background: any BackgroundExecution
  let journal: any SquishJournal
  let allowNetwork: Bool

  /// Sweeps scratch files older than an hour left by a previous run.
  init(gateway: any PhotoLibraryGateway, journal: any SquishJournal, workspace: SquishWorkspace, space: SquishDiskSpace,
       background: any BackgroundExecution, allowNetwork: Bool) {
    self.gateway = gateway; self.journal = journal; self.workspace = workspace; self.space = space
    self.background = background; self.allowNetwork = allowNetwork
    workspace.sweepStale()
  }

  private func requireFullAccess() throws {
    if gateway.accessLevel != .full { throw ReplaceError.needsFullAccess }
  }

  private static func unique<T>(_ items: [T], key: (T) -> String) -> [T] {
    var seen = Set<String>()
    return items.filter { seen.insert(key($0)).inserted }
  }

  // MARK: Step 1

  public func prepare(_ items: [SquishItem], progress: (@Sendable (SquishProgress) -> Void)? = nil) async -> PrepareReport {
    var report = PrepareReport()
    let items = Self.unique(items, key: \.assetID)
    if gateway.accessLevel != .full {
      report.failures = items.map { PrepareFailure(assetID: $0.assetID, error: .needsFullAccess) }
      return report
    }
    let expired = Flag()
    for item in items {
      if Task.isCancelled || expired.isSet { report.cancelled = true; break }
      do {
        report.prepared.append(try await runInBackground(expired) { try await self.prepareOne(item, progress: progress) })
      } catch let error as ReplaceError {
        if error == .cancelled { report.cancelled = true; break }
        report.failures.append(PrepareFailure(assetID: item.assetID, error: error))
      } catch {
        report.failures.append(PrepareFailure(assetID: item.assetID, error: .squish(.exportFailed(error))))
      }
      // Background time ran out while this item was finishing: it is kept, but nothing further is started.
      if expired.isSet { report.cancelled = true; break }
    }
    return report
  }

  /// Runs `work` in its own task so a background-time expiration (or the caller's cancel) can cancel just this item.
  private func runInBackground(_ expired: Flag, _ work: @escaping @Sendable () async throws -> Prepared) async throws -> Prepared {
    let task = Task { try await work() }
    let token = background.begin(name: "roll-squish") { expired.set(); task.cancel() }
    defer { if let token { background.end(token) } }
    do {
      return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    } catch let e as ReplaceError {
      throw e
    } catch let e as SquishError {
      throw Self.map(e)
    } catch is CancellationError {
      throw ReplaceError.cancelled
    } catch {
      throw ReplaceError.squish(.exportFailed(error))
    }
  }

  private static func map(_ e: SquishError) -> ReplaceError {
    switch e {
    case let .ineligible(reason): .ineligible(reason)
    case .cancelled: .cancelled
    default: .squish(e)
    }
  }

  private func prepareOne(_ item: SquishItem, progress: (@Sendable (SquishProgress) -> Void)?) async throws -> Prepared {
    @Sendable func report(_ phase: SquishPhase, _ fraction: Double? = nil) {
      progress?(SquishProgress(assetID: item.assetID, phase: phase, fraction: fraction))
    }

    // Checks before any work.
    let library = try await gateway.inspect(item.assetID)
    if let reason = SquishEligibility.reason(for: library.facts) { throw ReplaceError.ineligible(reason) }
    try space.check(sourceBytes: item.estimatedBytes)
    try Task.checkCancellation()

    let dir = try workspace.makeItemDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }  // runs on success, failure and cancel

    report(.downloading, 0)
    let source = try await gateway.exportOriginal(item.assetID, to: dir, allowNetwork: allowNetwork) { report(.downloading, $0) }
    workspace.touch(dir)
    try Task.checkCancellation()

    // The export must be the real thing (not truncated or a thumbnail) and must leave room for the output.
    let isVideo = library.facts.mediaType == SquishCandidates.videoMediaType
    if isVideo {
      try await SourceCheck.verifyVideo(source, assetWidth: library.pixelWidth, assetHeight: library.pixelHeight)
    } else {
      try SourceCheck.verifyPhoto(source, assetWidth: library.pixelWidth, assetHeight: library.pixelHeight)
    }
    try space.checkRoomForOutput(exportedBytes: try SquishVerify.fileSize(source))

    report(.encoding)
    let squished: URL
    let result: SquishResult
    let expectedUTI: String
    if isVideo {
      let mp4 = source.pathExtension.lowercased() == "mp4"
      squished = dir.appendingPathComponent("squished." + (mp4 ? "mp4" : "mov"))
      expectedUTI = mp4 ? "public.mpeg-4" : "com.apple.quicktime-movie"
      result = try await VideoSquisher.squish(input: source, output: squished, keep4K: item.keep4K)
    } else {
      squished = dir.appendingPathComponent("squished.heic")
      expectedUTI = "public.heic"
      result = try PhotoSquisher.squish(input: source, output: squished)
    }
    try? FileManager.default.removeItem(at: source)  // free the big file as early as possible
    workspace.touch(dir)
    let digest = try FileDigest.of(squished)  // before the library takes the file
    try Task.checkCancellation()

    // From here on the library changes, so the rest runs shielded from cancellation (a cancel or background expiry must
    // not leave a copy half-recorded or unverified).
    return try await Task.detached {
      try await self.saveAndVerify(item, library: library, squished: squished, result: result, digest: digest,
                                   isVideo: isVideo, expectedUTI: expectedUTI, progress: progress)
    }.value
  }

  private func saveAndVerify(_ item: SquishItem, library: LibraryAsset, squished: URL, result: SquishResult, digest: FileDigest,
                             isVideo: Bool, expectedUTI: String,
                             progress: (@Sendable (SquishProgress) -> Void)?) async throws -> Prepared {
    @Sendable func report(_ phase: SquishPhase) { progress?(SquishProgress(assetID: item.assetID, phase: phase, fraction: nil)) }

    // Write the journal before asking the library for a copy, so a crash from here on can be reconciled.
    do { try await journal.begin(assetID: item.assetID, originalBytes: result.inputBytes, newBytes: result.outputBytes) }
    catch { throw ReplaceError.createFailed(error) }

    report(.saving)
    let base = (library.originalFilename as NSString).deletingPathExtension
    let journalError = ErrorBox()
    let journal = self.journal, assetID = item.assetID
    let newID: String
    do {
      newID = try await gateway.createCopy(of: assetID, from: squished, filename: base + "." + squished.pathExtension) { id in
        do { try journal.noteNewAsset(assetID: assetID, newAssetID: id) } catch { journalError.record(error) }
      }
    } catch {
      try? await journal.setState(assetID: assetID, state: .discarded, payload: nil)  // nothing was created
      throw error
    }
    if journalError.error != nil {
      throw ReplaceError.verificationFailed(reason: "journal write failed", newAssetId: newID)
    }

    report(.verifying)
    guard let before = await gateway.fingerprint(item.assetID) else {
      // The original is gone, so the copy is now the only version: never offer it for cleanup.
      throw ReplaceError.verificationFailed(reason: "original not found", newAssetId: nil)
    }
    guard let after = await gateway.fingerprint(newID) else {
      throw ReplaceError.verificationFailed(reason: "new asset not found", newAssetId: nil)
    }
    if let problem = AssetFingerprint.mismatch(source: before, new: after, keep4K: item.keep4K) {
      throw ReplaceError.verificationFailed(reason: problem, newAssetId: newID)
    }
    let stored: CopyReadBack
    do { stored = try await gateway.readBack(newID) }
    catch { throw ReplaceError.verificationFailed(reason: "could not read the copy back", newAssetId: newID) }
    if let problem = stored.problem(expectedKind: isVideo ? .video : .photo, expectedUTI: expectedUTI, digest: digest) {
      throw ReplaceError.verificationFailed(reason: problem, newAssetId: newID)
    }

    let prepared = Prepared(assetID: item.assetID, newAssetID: newID, originalBytes: result.inputBytes,
                            newBytes: result.outputBytes, keep4K: item.keep4K, verifiedOriginal: before, verifiedCopy: after)
    do { try await journal.setState(assetID: item.assetID, state: .verified, payload: try JSONEncoder().encode(prepared)) }
    catch { throw ReplaceError.verificationFailed(reason: "journal write failed", newAssetId: newID) }
    return prepared
  }

  // MARK: Step 2 and recovery

  /// Deletes the originals that are still exactly as verified, in one change request. Each pair is re-read inside the
  /// change block: an original that was edited, favorited, added to an album, or whose copy has vanished is skipped (see
  /// `SquishCommitResult.skipped`) and left alone. Throws `ReplaceError.userDeclinedDelete` if the user declines;
  /// nothing is deleted then and the same `prepared` values can be retried or discarded. A second commit of the same
  /// batch finds the originals gone and changes nothing.
  public func commitDeletes(_ prepared: [Prepared]) async throws -> SquishCommitResult {
    try requireFullAccess()
    let items = Self.unique(prepared, key: \.assetID)
    guard !items.isEmpty else { return SquishCommitResult(deleted: [], skipped: [], recentlyDeletedPending: false) }
    let outcomes = try await gateway.deleteGuarded(items)
    var deleted: [Prepared] = [], skipped: [SkippedItem] = []
    for o in outcomes {
      if let reason = o.skip {
        skipped.append(SkippedItem(prepared: o.prepared, reason: reason))
        // An original that is already gone means the job is done; anything else stays open for the user.
        if reason == .originalMissing { try? await journal.setState(assetID: o.prepared.assetID, state: .committed, payload: nil) }
      } else {
        deleted.append(o.prepared)
        try? await journal.setState(assetID: o.prepared.assetID, state: .committed, payload: nil)
      }
    }
    return SquishCommitResult(deleted: deleted, skipped: skipped, recentlyDeletedPending: !deleted.isEmpty)
  }

  /// Same as `commitDeletes`; the name documents intent after `.userDeclinedDelete`.
  public func retryDelete(_ prepared: [Prepared]) async throws -> SquishCommitResult {
    try await commitDeletes(prepared)
  }

  /// Removes a leftover copy (for example after `.verificationFailed` or a declined delete).
  public func discardCopy(newAssetId: String) async throws { try await discardCopies([newAssetId]) }

  /// Removes several leftover copies with one system prompt.
  public func discardCopies(_ newAssetIds: [String]) async throws {
    try requireFullAccess()
    let ids = Self.unique(newAssetIds, key: { $0 })
    guard !ids.isEmpty else { return }
    try await gateway.delete(ids)
    for row in try await journal.entries(states: [.creating, .created, .verified]) where row.newAssetID.map(ids.contains) == true {
      try? await journal.setState(assetID: row.assetID, state: .discarded, payload: nil)
    }
  }

  /// Run on launch. Settles every open journal row against the library: rows whose copy never appeared are closed,
  /// rows whose original is gone are completed, verified copies come back as `pending` (retry or discard), and copies
  /// that exist but were never verified are listed as `orphans` for the user to discard.
  public func reconcile() async throws -> JournalReconciliation {
    try requireFullAccess()
    var result = JournalReconciliation()
    for row in try await journal.entries(states: [.creating, .created, .verified]) {
      func close(_ state: SquishJournalRecord.State) async { try? await journal.setState(assetID: row.assetID, state: state, payload: nil) }
      guard let newID = row.newAssetID else { await close(.discarded); continue }  // the copy was never requested
      guard await gateway.fingerprint(newID) != nil else { await close(.discarded); continue }
      guard await gateway.fingerprint(row.assetID) != nil else { await close(.committed); continue }  // the copy is all that is left
      if row.state == .verified, let data = row.payload, let prepared = try? JSONDecoder().decode(Prepared.self, from: data) {
        result.pending.append(prepared)
      } else {
        result.orphans.append(OrphanCopy(assetID: row.assetID, newAssetID: newID))
      }
    }
    return result
  }
}

// MARK: - PhotoKit (iOS)

#if canImport(Photos) && os(iOS)
extension ReplaceFlow {
  /// The production flow. `allowNetwork` lets the original download from iCloud (the UI offers this on Wi-Fi only).
  /// `journal` is normally the app's `Repositories`.
  public convenience init(journal: any SquishJournal, allowNetwork: Bool = false,
                          background: any BackgroundExecution = NoBackgroundExecution(),
                          workspace: SquishWorkspace = SquishWorkspace()) {
    self.init(gateway: PhotoKitGateway(), journal: journal, workspace: workspace,
              space: SquishDiskSpace(volumeOf: workspace.root.deletingLastPathComponent()),
              background: background, allowNetwork: allowNetwork)
  }
}

struct PhotoKitGateway: PhotoLibraryGateway {
  var accessLevel: LibraryAccessLevel {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized: .full
    case .limited: .limited
    default: .denied
    }
  }

  private func requireFullAccess() throws {
    if accessLevel != .full { throw ReplaceError.needsFullAccess }
  }

  // MARK: Reading

  private static func fetchOptions() -> PHFetchOptions {
    let o = PHFetchOptions()
    o.includeHiddenAssets = true
    return o
  }

  private static func fetch(_ id: String) -> PHAsset? {
    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: fetchOptions()).firstObject
  }

  private static func resources(of asset: PHAsset) -> [PHAssetResource] {
    PHAssetResource.assetResources(for: asset).filter { $0.type != .photoProxy }
  }

  private static func kind(_ r: PHAssetResource) -> AssetFacts.Resource {
    switch r.type {
    case .photo: .photo
    case .video: .video
    case .alternatePhoto: .alternatePhoto
    case .fullSizePhoto, .fullSizeVideo, .adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo,
         .adjustmentBasePairedVideo, .fullSizePairedVideo: .edit
    case .pairedVideo: .pairedVideo
    default: .other
    }
  }

  private static func mainResource(_ resources: [PHAssetResource]) -> PHAssetResource? {
    resources.first { $0.type == .photo || $0.type == .video }
  }

  private static func facts(_ asset: PHAsset) -> AssetFacts {
    let res = resources(of: asset)
    return AssetFacts(mediaType: asset.mediaType.rawValue, subtypes: Int(asset.mediaSubtypes.rawValue), resources: res.map(kind),
                      burstIdentifier: asset.burstIdentifier, isUserLibrary: asset.sourceType == .typeUserLibrary,
                      uti: mainResource(res)?.uniformTypeIdentifier)
  }

  private static func isWritableUserAlbum(_ c: PHAssetCollection) -> Bool {
    c.assetCollectionSubtype == .albumRegular && c.canPerform(.addContent)
  }

  private static func fingerprint(_ a: PHAsset) -> AssetFingerprint {
    var albums = Set<String>()
    PHAssetCollection.fetchAssetCollectionsContaining(a, with: .album, options: nil).enumerateObjects { c, _, _ in
      if isWritableUserAlbum(c) { albums.insert(c.localIdentifier) }
    }
    return AssetFingerprint(isVideo: a.mediaType == .video, duration: a.duration, pixelWidth: a.pixelWidth,
                            pixelHeight: a.pixelHeight, creationDate: a.creationDate, modificationDate: a.modificationDate,
                            isFavorite: a.isFavorite, isHidden: a.isHidden, latitude: a.location?.coordinate.latitude,
                            longitude: a.location?.coordinate.longitude, albumIDs: albums)
  }

  private static func snapshot(_ a: PHAsset) -> LibrarySnapshot { LibrarySnapshot(fingerprint: fingerprint(a), facts: facts(a)) }

  func inspect(_ assetID: String) async throws -> LibraryAsset {
    try requireFullAccess()
    guard let asset = Self.fetch(assetID) else { throw ReplaceError.assetNotFound }
    let main = Self.mainResource(Self.resources(of: asset))
    return LibraryAsset(facts: Self.facts(asset), originalFilename: main?.originalFilename ?? "asset",
                        pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
  }

  func fingerprint(_ assetID: String) async -> AssetFingerprint? { Self.fetch(assetID).map(Self.fingerprint) }

  // MARK: Streaming a resource

  /// Streams a resource with a cancellable request (`writeData` has no request id to cancel).
  private func stream(_ resource: PHAssetResource, allowNetwork: Bool, progress: (@Sendable (Double) -> Void)?,
                      onData: @escaping @Sendable (Data) -> Void) async throws {
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = allowNetwork
    if let progress { options.progressHandler = progress }
    let manager = PHAssetResourceManager.default()
    let state = RequestState()
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
          state.install(cont)
          let id = manager.requestData(for: resource, options: options, dataReceivedHandler: onData,
                                       completionHandler: { error in
            if let error { state.finish(.failure(error)) } else { state.finish(.success(())) }
          })
          state.setRequest(id) { manager.cancelDataRequest($0) }
        }
      } onCancel: {
        state.cancel { manager.cancelDataRequest($0) }
      }
    } catch is CancellationError {
      throw ReplaceError.cancelled
    } catch {
      if Task.isCancelled { throw ReplaceError.cancelled }
      if (error as? PHPhotosError)?.code == .networkAccessRequired { throw ReplaceError.needsDownload }
      throw ReplaceError.resourceExportFailed(error)
    }
  }

  func exportOriginal(_ assetID: String, to directory: URL, allowNetwork: Bool,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    try requireFullAccess()
    guard let asset = Self.fetch(assetID), let resource = Self.mainResource(Self.resources(of: asset)) else {
      throw ReplaceError.assetNotFound
    }
    let url = directory.appendingPathComponent("original-" + resource.originalFilename)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw ReplaceError.resourceExportFailed(CocoaError(.fileWriteUnknown))
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let sink = FileSink(handle)
    try await stream(resource, allowNetwork: allowNetwork, progress: progress) { sink.write($0) }
    if let e = sink.error { throw ReplaceError.resourceExportFailed(e) }
    return url
  }

  func readBack(_ assetID: String) async throws -> CopyReadBack {
    try requireFullAccess()
    guard let asset = Self.fetch(assetID) else { throw ReplaceError.assetNotFound }
    let res = Self.resources(of: asset)
    guard let main = Self.mainResource(res) else {
      return CopyReadBack(resources: res.map(Self.kind), uti: nil, bytes: 0, sha256: "")
    }
    let hasher = HashSink()
    try await stream(main, allowNetwork: false, progress: nil) { hasher.update($0) }
    let digest = hasher.finish()
    return CopyReadBack(resources: res.map(Self.kind), uti: main.uniformTypeIdentifier, bytes: digest.bytes, sha256: digest.sha256)
  }

  // MARK: Writing

  func createCopy(of assetID: String, from file: URL, filename: String,
                  onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> String {
    try requireFullAccess()
    let box = IDBox()
    let resourceOptions = PHAssetResourceCreationOptions()
    resourceOptions.originalFilename = filename
    resourceOptions.shouldMoveFile = true
    do {
      try await PHPhotoLibrary.shared().performChanges {
        // Re-read the original inside the block. If it is gone, create nothing.
        guard let original = Self.fetch(assetID) else { return }
        let request = PHAssetCreationRequest.forAsset()
        // Read the id before adding the resource: with no placeholder nothing has been created.
        guard let placeholder = request.placeholderForCreatedAsset else { return }
        box.id = placeholder.localIdentifier
        onPlaceholder(placeholder.localIdentifier)
        request.addResource(with: original.mediaType == .video ? .video : .photo, fileURL: file, options: resourceOptions)
        request.creationDate = original.creationDate
        request.location = original.location
        request.isFavorite = original.isFavorite
        request.isHidden = original.isHidden
        PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil).enumerateObjects { collection, _, _ in
          guard Self.isWritableUserAlbum(collection), let change = PHAssetCollectionChangeRequest(for: collection) else { return }
          if let index = Self.manualIndex(of: original, in: collection) {
            change.insertAssets([placeholder] as NSArray, at: IndexSet(integer: index + 1))  // right after the original
          } else {
            change.addAssets([placeholder] as NSArray)
          }
        }
      }
    } catch { throw ReplaceError.createFailed(error) }
    guard let id = box.id else { throw ReplaceError.createFailed(ReplaceError.assetNotFound) }
    return id
  }

  /// The original's position in an album, but only when the album has a manual order (its order isn't just by date).
  /// Albums are capped at 5,000 assets for this check; bigger ones just get the copy appended.
  private static func manualIndex(of asset: PHAsset, in collection: PHAssetCollection) -> Int? {
    let inAlbum = PHAsset.fetchAssets(in: collection, options: nil)
    guard inAlbum.count <= 5_000 else { return nil }
    let index = inAlbum.index(of: asset)
    guard index != NSNotFound else { return nil }
    var last = Date.distantPast
    var sortedByDate = true
    inAlbum.enumerateObjects { a, _, stop in
      let d = a.creationDate ?? .distantPast
      if d < last { sortedByDate = false; stop.pointee = true }
      last = d
    }
    return sortedByDate ? nil : index
  }

  func deleteGuarded(_ items: [Prepared]) async throws -> [GuardedOutcome] {
    try requireFullAccess()
    let box = OutcomeBox()
    do {
      try await PHPhotoLibrary.shared().performChanges {
        // The last look: both assets are re-read here, synchronously, in the same block that deletes.
        var outcomes: [GuardedOutcome] = [], doomed: [PHAsset] = []
        for p in items {
          let original = Self.fetch(p.assetID), copy = Self.fetch(p.newAssetID)
          let reason = CommitGuard.decide(p, original: original.map(Self.snapshot), copy: copy.map(Self.snapshot))
          outcomes.append(GuardedOutcome(prepared: p, skip: reason))
          if reason == nil, let original { doomed.append(original) }
        }
        box.outcomes = outcomes
        if !doomed.isEmpty { PHAssetChangeRequest.deleteAssets(doomed as NSArray) }
      }
    } catch {
      if (error as? PHPhotosError)?.code == .userCancelled { throw ReplaceError.userDeclinedDelete }
      throw ReplaceError.deleteFailed(error)
    }
    return box.outcomes
  }

  func delete(_ copyIDs: [String]) async throws {
    try requireFullAccess()
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: copyIDs, options: Self.fetchOptions()))
      }
    } catch {
      if (error as? PHPhotosError)?.code == .userCancelled { throw ReplaceError.userDeclinedDelete }
      throw ReplaceError.deleteFailed(error)
    }
  }
}

private final class IDBox: @unchecked Sendable { var id: String? }
private final class OutcomeBox: @unchecked Sendable { var outcomes: [GuardedOutcome] = [] }

private final class FileSink: @unchecked Sendable {
  private let handle: FileHandle
  private let firstError = Mutex<(any Error)?>(nil)
  init(_ handle: FileHandle) { self.handle = handle }
  func write(_ data: Data) {
    do { try handle.write(contentsOf: data) } catch { firstError.withLock { if $0 == nil { $0 = error } } }
  }
  var error: (any Error)? { firstError.withLock { $0 } }
}

private final class HashSink: @unchecked Sendable {
  private let hasher = Mutex(FileDigest.Hasher())
  func update(_ data: Data) { hasher.withLock { $0.update(data) } }
  func finish() -> FileDigest { hasher.withLock { $0.finish() } }
}

/// Resumes the stream continuation exactly once, whichever of completion and cancel comes first, and cancels the
/// PhotoKit request even if the cancel arrives before the request id is known.
private final class RequestState: @unchecked Sendable {
  private struct S {
    var continuation: CheckedContinuation<Void, any Error>?
    var requestID: PHAssetResourceDataRequestID?
    var cancelled = false
    var finished = false
  }
  private let state = Mutex(S())

  func install(_ c: CheckedContinuation<Void, any Error>) { state.withLock { $0.continuation = c } }

  func setRequest(_ id: PHAssetResourceDataRequestID, cancel: (PHAssetResourceDataRequestID) -> Void) {
    let wasCancelled = state.withLock { s -> Bool in s.requestID = id; return s.cancelled }
    if wasCancelled { cancel(id); finish(.failure(CancellationError())) }
  }

  func cancel(_ cancelRequest: (PHAssetResourceDataRequestID) -> Void) {
    let id = state.withLock { s -> PHAssetResourceDataRequestID? in s.cancelled = true; return s.requestID }
    if let id { cancelRequest(id); finish(.failure(CancellationError())) }
  }

  func finish(_ result: Result<Void, any Error>) {
    let c = state.withLock { s -> CheckedContinuation<Void, any Error>? in
      guard !s.finished, let c = s.continuation else { return nil }
      s.finished = true
      return c
    }
    c?.resume(with: result)
  }
}
#endif
