import Foundation
import Entitlements
import Store
#if canImport(Photos) && os(iOS)
import Photos
#endif

// This file and Squish/ReplaceFlow.swift are the only places allowed to make destructive PhotoKit calls.

// MARK: - Public model

public enum CommitProgress: Sendable, Equatable {
  /// `done` of `total` deletes confirmed so far; emitted before each prompt and once at the end.
  case deleting(done: Int, total: Int)
  case addingToAlbum(name: String)
  case squishing(SquishRunProgress)
  /// The single prompt deleting the squished originals is about to show.
  case deletingSquishedOriginals(count: Int)
}

/// What a commit did. Everything listed here really happened and is already recorded in the Store.
public struct CommitReport: Sendable, Equatable {
  public var deleted: [String] = []
  public var addedToAlbums: [String: [String]] = [:]
  /// Originals replaced by their smaller copy.
  public var squished: [SquishedCopy] = []
  /// Squishes whose original changed (or whose copy vanished) before the delete; their originals were kept and stay
  /// queued. Their copies can be removed with `PhotoKitCommitter.discardCopies`.
  public var squishSkipped: [SquishedCopy] = []
  /// Squishes the runner couldn't check any more (no verified record of the copy); originals kept. Relaunching
  /// reconciles them.
  public var squishUnregistered: [SquishedCopy] = []
  /// Verified copies `retrySquishDeletes` didn't finish because the free quota ran out (not Pro). Nothing was changed
  /// for them: offer the paywall or `discardCopies`.
  public var squishBlockedByQuota: [SquishedCopy] = []
  public var squishFailures: [SquishFailure] = []
  /// Copies left behind by failed verification (`PhotoKitCommitter.discardCopies`).
  public var leftoverCopyIDs: [String] = []
  /// Copies made whose originals are still there (the squish prompt was declined or the run was cancelled).
  /// Offer `PhotoKitCommitter.retrySquishDeletes` or `discardCopies`.
  public var pendingSquishCopies: [SquishedCopy] = []
  /// Squishes not attempted because no `SquishRunner` was given; they stay queued.
  public var squishUnavailable: [String] = []
  /// Free-quota items spent (0 for Pro).
  public var quotaSpent = 0

  public init() {}

  /// About how much deleting the squished originals frees, once Recently Deleted is emptied (or in 30 days).
  public var estimatedSquishSavings: Int64 { squished.reduce(0) { $0 + $1.estimatedSavings } }
}

public enum CommitOutcome: Sendable, Equatable {
  case applied(CommitReport)
  /// The user declined a system prompt, or the task was cancelled. The declined change and everything after it
  /// was not applied and cost nothing. The report holds what was confirmed before (normally nothing, since the
  /// first delete prompt comes first).
  case cancelled(CommitReport)
}

/// A library change failed for another reason than a user cancel, or the Store couldn't record a change.
public struct CommitFailure: Error {
  public let underlying: any Error
  /// What had already been applied (and recorded) before the failure.
  public let report: CommitReport
}

// MARK: - Library seam (the only thing that touches PhotoKit)

enum CommitLibraryError: Error, Equatable {
  /// The user tapped Don't Allow on the system confirmation.
  case userCancelled
}

protocol CommitLibrary: Sendable {
  /// Deletes in one change request (one system prompt). Throws `CommitLibraryError.userCancelled` on a user cancel.
  func delete(_ ids: [String]) async throws
  /// In one change request: finds the user album titled `name` (or creates it) and adds the assets.
  func addToAlbum(named name: String, _ ids: [String]) async throws
}

// MARK: - Committer

/// Applies a `CommitPlan` to the photo library, then records it.
///
/// Order: plain deletes first, in chunks of `deleteChunk` per change request (one iOS confirmation each, the
/// minimum PhotoKit allows for large batches); then album moves, one change request per album, sorted by title;
/// then squishes, prepared as one batch and their originals deleted in one more prompt (Squish verifies each copy
/// before anything is deleted). Declining the first prompt therefore applies nothing at all.
///
/// After each change succeeds, its decisions are marked applied and deleted assets flagged (one Store
/// transaction), then free quota is spent for the distinct assets it changed, unless Pro. A cancelled or failed
/// change costs nothing. If the quota ran out in the meantime (a race), the remainder is still used up.
public final class PhotoKitCommitter: Sendable {
  public static let deleteChunk = 500

  let library: any CommitLibrary
  let repositories: Repositories
  let quota: FreeQuota
  let pro: any ProStatus
  let squish: (any SquishRunner)?

  init(library: any CommitLibrary, database: AppDatabase, pro: any ProStatus, squish: (any SquishRunner)?) {
    self.library = library
    self.repositories = Repositories(database)
    self.quota = FreeQuota(database)
    self.pro = pro
    self.squish = squish
  }

  public func apply(_ plan: CommitPlan, progress: (@Sendable (CommitProgress) -> Void)? = nil) async throws -> CommitOutcome {
    var run = Run(plan: plan, isPro: await pro.isPro)
    if Task.isCancelled { return .cancelled(run.report) }
    try await settle(&run, [], deleted: [], extra: plan.stale)

    // 1. Plain deletes.
    let total = plan.deletes.count
    for start in stride(from: 0, to: total, by: Self.deleteChunk) {
      let chunk = Array(plan.deletes[start..<min(start + Self.deleteChunk, total)])
      if Task.isCancelled { return .cancelled(run.report) }
      progress?(.deleting(done: start, total: total))
      if let stop = try await change(run.report, { try await self.library.delete(chunk) }) { return stop }
      run.report.deleted += chunk
      try await settle(&run, chunk.map { .delete($0) }, deleted: chunk)
    }
    if total > 0 { progress?(.deleting(done: total, total: total)) }

    // 2. Album moves.
    for name in plan.albumMoves.keys.sorted() {
      let ids = plan.albumMoves[name] ?? []
      guard !ids.isEmpty else { continue }
      if Task.isCancelled { return .cancelled(run.report) }
      progress?(.addingToAlbum(name: name))
      if let stop = try await change(run.report, { try await self.library.addToAlbum(named: name, ids) }) { return stop }
      run.report.addedToAlbums[name] = ids
      try await settle(&run, ids.map { .album(name: name, assetId: $0) }, deleted: [])
    }

    // 3. Squishes.
    guard !plan.squishes.isEmpty else { return .applied(run.report) }
    guard let squish else {
      run.report.squishUnavailable = plan.squishes.map(\.assetID)
      return .applied(run.report)
    }
    if Task.isCancelled { return .cancelled(run.report) }
    let batch = await squish.prepare(plan.squishes) { progress?(.squishing($0)) }
    run.report.squishFailures = batch.failures
    run.report.leftoverCopyIDs = batch.leftoverCopyIDs
    if batch.cancelled || Task.isCancelled {
      run.report.pendingSquishCopies = batch.prepared
      return .cancelled(run.report)
    }
    guard !batch.prepared.isEmpty else { return .applied(run.report) }
    progress?(.deletingSquishedOriginals(count: batch.prepared.count))
    return try await deleteSquished(batch.prepared, run: &run)
  }

  /// After a declined squish prompt (or for copies an interrupted squish left): asks again to delete the originals of
  /// `pending` (from `CommitReport.pendingSquishCopies` or `reconcile()`) and records them against `plan`. Without
  /// Pro only as many as the free quota has left are finished, in order; the rest are listed in
  /// `squishBlockedByQuota` and nothing happens to them.
  public func retrySquishDeletes(_ pending: [SquishedCopy], of plan: CommitPlan) async throws -> CommitOutcome {
    var run = Run(plan: plan, isPro: await pro.isPro)
    guard !pending.isEmpty else { return .applied(run.report) }
    guard squish != nil else {
      run.report.squishUnavailable = pending.map(\.assetID)
      return .applied(run.report)
    }
    var allowed = pending
    if !run.isPro {
      let remaining: Int
      do { remaining = try await quota.remaining() } catch { throw CommitFailure(underlying: error, report: run.report) }
      allowed = Array(pending.prefix(remaining))
      run.report.squishBlockedByQuota = Array(pending.dropFirst(allowed.count))
    }
    guard !allowed.isEmpty else { return .applied(run.report) }
    return try await deleteSquished(allowed, run: &run)
  }

  /// Removes leftover squish copies (one system prompt). Their originals were never touched.
  public func discardCopies(_ newAssetIDs: [String]) async throws {
    guard !newAssetIDs.isEmpty, let squish else { return }
    try await squish.discardCopies(newAssetIDs)
  }

  // MARK: Steps

  private struct Run {
    let plan: CommitPlan
    let isPro: Bool
    var report = CommitReport()
    /// Assets already counted against the quota in this run.
    var charged: Set<String> = []
  }

  private func deleteSquished(_ prepared: [SquishedCopy], run: inout Run) async throws -> CommitOutcome {
    let squish = squish!
    let result: SquishDeletion
    do {
      result = try await squish.commitDeletes(prepared)
    } catch SquishRunnerError.userDeclinedDelete {
      run.report.pendingSquishCopies = prepared
      return .cancelled(run.report)
    } catch {
      run.report.pendingSquishCopies = prepared
      throw CommitFailure(underlying: error, report: run.report)
    }
    run.report.squished = result.deleted
    run.report.squishSkipped = result.skipped
    run.report.squishUnregistered = result.unregistered
    let ids = result.deleted.map(\.assetID)
    try await settle(&run, ids.map { .squish($0) }, deleted: ids)
    return .applied(run.report)
  }

  /// Runs one library change. Returns `.cancelled` when the user declined it; throws `CommitFailure` on any other error.
  private func change(_ report: CommitReport, _ body: () async throws -> Void) async throws -> CommitOutcome? {
    do {
      try await body()
      return nil
    } catch CommitLibraryError.userCancelled {
      return .cancelled(report)
    } catch {
      throw CommitFailure(underlying: error, report: report)
    }
  }

  /// Records a change that succeeded, then spends quota for the assets it changed that this run hasn't charged yet.
  private func settle(_ run: inout Run, _ ops: [CommitOperation], deleted: [String], extra: [DecisionKey] = []) async throws {
    let keys = extra + ops.flatMap { run.plan.settles[$0] ?? [] }
    do {
      try await repositories.recordApplied(keys, deletedAssetIds: deleted)
      let fresh = Set(ops.map(\.assetId)).subtracting(run.charged)
      run.charged.formUnion(fresh)
      if !run.isPro, !fresh.isEmpty { run.report.quotaSpent += try await quota.consumeUpTo(fresh.count) }
    } catch {
      throw CommitFailure(underlying: error, report: run.report)
    }
  }
}

// MARK: - PhotoKit (iOS)

#if canImport(Photos) && os(iOS)
extension PhotoKitCommitter {
  /// The production committer. Pass a `SquishRunner` (Squish's `ReplaceFlow`, adapted) to apply squishes;
  /// without one they stay queued.
  public convenience init(database: AppDatabase, pro: any ProStatus, squish: (any SquishRunner)? = nil) {
    self.init(library: PhotoKitCommitLibrary(), database: database, pro: pro, squish: squish)
  }
}

struct PhotoKitCommitLibrary: CommitLibrary {
  private static func fetchOptions() -> PHFetchOptions {
    let o = PHFetchOptions()
    o.includeHiddenAssets = true
    return o
  }

  func delete(_ ids: [String]) async throws {
    try await perform {
      PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.fetchOptions()))
    }
  }

  func addToAlbum(named name: String, _ ids: [String]) async throws {
    try await perform {
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.fetchOptions())
      if let album = Self.userAlbum(named: name), let request = PHAssetCollectionChangeRequest(for: album) {
        request.addAssets(assets)
      } else {
        PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).addAssets(assets)
      }
    }
  }

  /// The first regular user album with exactly this title that accepts new content.
  private static func userAlbum(named name: String) -> PHAssetCollection? {
    var match: PHAssetCollection?
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, stop in
      if c.localizedTitle == name, c.canPerform(.addContent) {
        match = c
        stop.pointee = true
      }
    }
    return match
  }

  private func perform(_ changes: @escaping @Sendable () -> Void) async throws {
    do {
      try await PHPhotoLibrary.shared().performChanges(changes)
    } catch {
      if (error as? PHPhotosError)?.code == .userCancelled { throw CommitLibraryError.userCancelled }
      throw error
    }
  }
}
#endif
