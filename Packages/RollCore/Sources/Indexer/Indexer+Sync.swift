import CoreGraphics
import Embedding
import Foundation
import Library
import os
import Signals
import Store
import Synchronization

extension Indexer {
  // MARK: - Library sync

  /// Mirrors the whole library into the Store: new ids (and known ids still missing a UTI, retried once
  /// per sync) get their UTI looked up, known ids keep the stored one (`upsertAssets` COALESCEs it),
  /// `estBytes` is computed after the merge, and live rows the library no longer reports are marked
  /// deleted and their vectors purged. Runs after any earlier `sync()` / `apply(_:)` finished.
  @discardableResult
  public func sync() async throws -> SyncReport {
    try await enqueueLibraryChange { indexer in try await indexer.performSync() }
  }

  /// Applies one change notification, after any earlier `sync()` / `apply(_:)`. `requiresResync` runs a
  /// full sync; otherwise only the reported ids are read (ids that no longer resolve count as removed),
  /// and content changes reset the asset and purge its vector. Call `run()` afterwards.
  @discardableResult
  public func apply(_ change: LibraryChange) async throws -> SyncReport {
    try await enqueueLibraryChange { indexer in try await indexer.performApply(change) }
  }

  func enqueueLibraryChange(_ operation: @escaping @Sendable (Indexer) async throws -> SyncReport)
    async throws -> SyncReport {
    let previous = libraryChain
    let task = Task<SyncReport, Error> {
      _ = await previous?.result
      return try await operation(self)
    }
    libraryChain = task
    return try await task.value
  }

  func performSync() async throws -> SyncReport {
    let showsSyncing = current == nil
    if showsSyncing { publish(phase: .syncing) }
    defer { if showsSyncing && current == nil && progress.phase == .syncing { publish(phase: .idle) } }
    let snapshots = await library.fetchAll()
    let refs = try await repo.assetRefs(ids: nil)
    let (inserted, updated) = try await store(snapshots, known: refs)
    let live = Set(snapshots.map(\.id))
    let gone = refs.filter { !$0.deleted && !live.contains($0.id) }.map(\.id)
    try await repo.markDeleted(gone, at: Date())
    try await purgeDeletedVectors()
    return SyncReport(inserted: inserted, updated: updated, deleted: gone.count)
  }

  func performApply(_ change: LibraryChange) async throws -> SyncReport {
    if change.requiresResync { return try await performSync() }
    let removed = Set(change.removed)
    var seen = Set<String>()
    let touched = (change.inserted + change.changed + change.contentChanged)
      .filter { !removed.contains($0) && seen.insert($0).inserted }
    let snapshots = touched.isEmpty ? [] : await library.snapshots(ids: touched)
    let refs = try await repo.assetRefs(ids: touched + Array(removed))
    let (inserted, updated) = try await store(snapshots, known: refs.filter { !removed.contains($0.id) })
    let found = Set(snapshots.map(\.id))
    let gone = Set(change.removed + touched.filter { !found.contains($0) })
    let goneLive = refs.filter { gone.contains($0.id) && !$0.deleted }.map(\.id)
    try await repo.markDeleted(goneLive, at: Date())

    let edited = change.contentChanged.filter { found.contains($0) }
    if !edited.isEmpty {
      // Flags first (the reset clears `embedded`), then the stale vectors.
      _ = try await repo.resetForContentChange(ids: edited)
      dropBuffered(ids: Set(edited))
      // Without any store, the next open's reconcile removes them (no live row flags them any more).
      if let sink = purgeSink { try await enqueuePurge(clearing: [], removing: edited, sink: sink) }
    }
    try await purgeDeletedVectors()
    return SyncReport(inserted: inserted, updated: updated, deleted: goneLive.count)
  }

  /// Upserts library metadata. File types are never looked up here (one resource lookup per asset made the first sync
  /// of a 30k library the hottest part of a launch): rows keep a stored type, and `resolveTypes` fills in the ones that
  /// matter later. Until then the size estimate uses the default for an unknown type.
  func store(_ snapshots: [AssetSnapshot], known refs: [AssetRef]) async throws -> (inserted: Int, updated: Int) {
    guard !snapshots.isEmpty else { return (0, 0) }
    let known = Dictionary(refs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let newIds = snapshots.map(\.id).filter { known[$0] == nil }
    let records = snapshots.map { snapshot in
      var merged = snapshot
      merged.uti = snapshot.uti ?? known[snapshot.id]?.uti
      return AssetRecord(merged, estBytes: SizeEstimator.estimate(merged))
    }
    try await repo.upsertAssets(records)
    return (newIds.count, snapshots.count - newIds.count)
  }

  /// Photos at least this big may be Squish candidates (a PNG at 1.6 B/px over 3 MB), so their type matters.
  public static let typeLookupMinimumPixels = SizeEstimator.typeLookupMinimumPixels
  /// Upgrade attempts per preview row and launch: the pass starts again whenever Wi-Fi and charging hold, and a
  /// download that keeps failing (the original is unavailable, or iCloud refuses) must not be retried on each pass.
  public static let maxUpgradeAttempts = 2

  /// Kinds Squish never takes (Live, Portrait, animated, spatial), and screenshots (at most 0.40 B/px: never over
  /// 3 MB on an iPhone): their type doesn't matter for it.
  static let typeLookupExcludedSubtypes = MediaSubtype.livePhoto | MediaSubtype.depthEffect | MediaSubtype.animation
    | MediaSubtype.spatial | MediaSubtype.screenshot

  /// Looks up the file types of up to `limit` photos whose type matters (possible Squish candidates without a type),
  /// largest first, and stores them with the size estimates they imply. Returns how many were looked up. Run it lazily,
  /// at utility priority, after the first screen is up.
  @discardableResult
  public func resolveTypes(limit: Int) async throws -> Int {
    let ids = try await repo.typeLookupCandidates(minPixels: Self.typeLookupMinimumPixels,
                                                  excludingSubtypes: Self.typeLookupExcludedSubtypes, limit: limit)
    guard !ids.isEmpty else { return 0 }
    let utis = await library.utis(for: ids)
    let updates = try await repo.assets(ids: ids).map { r -> (id: String, uti: String, estBytes: Int64) in
      let uti = utis[r.id] ?? ""
      let estimate = SizeEstimator.estimate(
        mediaType: r.mediaType, pixelW: r.pixelW ?? 0, pixelH: r.pixelH ?? 0, duration: r.duration ?? 0,
        uti: uti.isEmpty ? nil : uti, fps: r.subtypes & MediaSubtype.videoHighFrameRate != 0 ? 60 : 30,
        isScreenshot: r.subtypes & MediaSubtype.screenshot != 0)
      return (r.id, uti, estimate)
    }
    try await repo.updateTypes(updates)
    return ids.count
  }

  /// Deleted rows still flagged `embedded`: clear the flag, remove the vector, save. Without any store the
  /// flags stay, and the purge happens once one is attached (or the next open's reconcile does it).
  func purgeDeletedVectors() async throws {
    guard let sink = purgeSink else { return }
    let ids = try await repo.deletedEmbeddedIds()
    guard !ids.isEmpty else { return }
    dropBuffered(ids: Set(ids))
    try await enqueuePurge(clearing: ids, removing: ids, sink: sink)
  }

  func dropBuffered(ids: Set<String>) {
    signalBuffer.removeAll { ids.contains($0.id) }
    vectorBuffer?.items.removeAll { ids.contains($0.id) }
  }
}
