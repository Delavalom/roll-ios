import CoreGraphics
import Embedding
import Foundation
import Library
import os
import Signals
import Store
import Synchronization

public enum IndexerError: Error, Equatable {
  /// The vector store was opened for another embedder revision or vector size. Open it with the
  /// embedder's `revision` and `dimensions` (a different revision wipes the old index, by design).
  case embedderMismatch(embedder: String, vectors: String)
  /// An embedder was given without a vector store to write to.
  case missingVectorStore
}

public struct IndexerConfig: Sendable {
  /// Assets per page; Vision signals (and failed loads) are committed after each page.
  public var pageSize = 200
  /// Assets between vector flushes (`upsert` → `save` → `markEmbedded`). A run that computed fewer new
  /// vectors than this only flushes at its end if `minimumSaveInterval` has passed since the last save.
  public var vectorFlushEvery = 2_000
  /// Debounce for small runs: their vectors stay buffered (and are not pending work) until this much
  /// time has passed since the last save, the app goes to the background, or `flush()` is called.
  public var minimumSaveInterval: Duration = .seconds(30)
  /// Longer side of the image fed to Vision and the embedder. 300 px is what the library answers locally for every asset
  /// (device probe, 2026-10-24: 100% of 400 sampled; 960 px only 4-15% on an Optimize Storage library), above the
  /// 256 px blur analysis and the grouping minimum (`AssetRecord.minimumGroupingSide`, 288 px: a little under, so a
  /// resize that comes back a few pixels short still groups).
  public var thumbnailSide = 300
  /// Thumbnails requested together. The next group is fetched while the current one is processed.
  /// Kept small on purpose: a decoded 960 px thumbnail is about 2.7 MB, so a whole 200-asset page
  /// in memory (twice, with prefetch) would be over 1 GB.
  public var thumbnailChunk = 8
  /// Where in a video the embedded frame is taken (spec §4: 10%).
  public var videoFrameFraction = 0.1
  /// Vector storage is pre-sized only when a pass brings more than this many new vectors (or more than
  /// 10% of the index), so small passes never trigger a reallocation.
  public var reserveThreshold = 1_024

  public init() {}
}

public struct IndexProgress: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case idle, syncing, started, indexing, thermalPause, finished, cancelled, failed
  }

  /// Which run this belongs to (increments per run; 0 before the first). Lets a subscriber that starts
  /// a run ignore updates from earlier ones.
  public var runId: Int
  public var processed: Int
  public var total: Int
  public var phase: Phase

  public init(runId: Int, processed: Int, total: Int, phase: Phase) {
    self.runId = runId; self.processed = processed; self.total = total; self.phase = phase
  }
}

/// What one `run()` did (all passes together).
public struct IndexReport: Sendable, Equatable {
  /// Assets visited, whatever the outcome.
  public var processed = 0
  public var signalsComputed = 0
  /// Vectors computed (written at a flush).
  public var embedded = 0
  /// Assets found only in iCloud during a local pass.
  public var cloudOnly = 0
  /// Analysed from the local preview of an iCloud-only original (`source = preview`).
  public var previews = 0
  /// Preview rows replaced by a full image (`run(upgradePreviews: true)`).
  public var upgraded = 0
  /// Thumbnails that failed (each adds a failed attempt; see `Schema.maxAttempts`).
  public var failed = 0
  /// Embedder errors and wrong-length vectors (the asset keeps its signals and is retried next run).
  public var embedFailures = 0
  /// Thermal polls slept.
  public var thermalPolls = 0
  public var passes = 0

  public init() {}
}

public struct SyncReport: Sendable, Equatable {
  public var inserted: Int
  public var updated: Int
  public var deleted: Int

  public init(inserted: Int, updated: Int, deleted: Int) {
    self.inserted = inserted; self.updated = updated; self.deleted = deleted
  }
}

enum IndexerLog {
  static let logger = Logger(subsystem: "com.delavalom.roll", category: "indexer")
}

/// Walks the photo library and fills the Store and the vector index.
///
/// - `sync()` / `apply(_:)` mirror library metadata into the Store, one at a time in call order. Assets
///   that leave the library are marked deleted and their vectors purged (flag first, then the vector,
///   then `save()`); content edits reset the asset and purge its vector.
/// - `run(limit:allowNetwork:)` computes Vision signals and (with an embedder attached) embeddings for
///   pending assets, one asset at a time, prefetching the next group of thumbnails. Signals are committed
///   every 200 assets; vectors are flushed every 2,000, at the end of a large run (small runs are
///   debounced, see `IndexerConfig.minimumSaveInterval`), on cancellation and on `flush()`, always as
///   `upsert` → `save()` → `markEmbedded`.
/// - Without an embedder (model not downloaded, or it failed to load: "search unavailable") only
///   signals run and `embedded` stays 0. `setEmbedder(_:openVectors:)` attaches the model later and runs
///   an embed-only catch-up. Never attach `StubEmbedder` outside tests and previews.
///
/// Concurrent `run()` calls share one run, which then makes another pass with the merged options
/// (network allowed if any caller allowed it; the larger limit, no limit winning). A caller that cancels
/// stops waiting; the run itself stops when its last caller cancels, or on `cancel()`. A call made while
/// a run is stopping queues a fresh run after it.
public actor Indexer {
  private let library: any LibrarySource
  private let signals: any SignalSource
  private let repo: any IndexRepository
  private let thermal: ThermalGate
  private let config: IndexerConfig

  private struct Embedding {
    let embedder: any Embedder
    let vectors: any VectorSink
    let generation: Int
  }

  private var embedding: Embedding?
  /// A store opened without an embedder (the model hasn't loaded yet; the store is at the last revision).
  /// Nothing is embedded into it, but deleted and edited assets lose their stale vectors right away.
  private var standingVectors: (any VectorSink)?
  private var generation = 0
  private var reservedCapacity = 0

  // Buffered writes.
  private struct VectorBatch: Sendable {
    let generation: Int
    let sink: any VectorSink
    var items: [(id: String, vector: [Float])]
  }

  private var signalBuffer: [SignalFields] = []
  private var failureBuffer: [String] = []
  private var vectorBuffer: VectorBatch?
  private var lastWrite: Task<Void, Error>?
  private var lastSave: ContinuousClock.Instant?

  // Serialised operations.
  private var libraryChain: Task<SyncReport, Error>?
  private var swapChain: Task<Void, Error>?

  // Runs.
  private struct PassOptions: Sendable, Equatable {
    var allowNetwork: Bool
    var limit: Int?
    /// Also re-analyse preview rows from full images (needs `allowNetwork`).
    var upgradePreviews = false

    func merged(with other: PassOptions) -> PassOptions {
      let limit: Int? = if let a = limit, let b = other.limit { max(a, b) } else { nil }
      return PassOptions(allowNetwork: allowNetwork || other.allowNetwork, limit: limit,
                         upgradePreviews: upgradePreviews || other.upgradePreviews)
    }
  }

  private struct Waiter {
    let continuation: CheckedContinuation<IndexReport, Error>
    let ticket: WaiterTicket
  }

  private final class Run {
    let id: Int
    let control = RunControl()
    var options: PassOptions
    var morePass: PassOptions?
    var waiters: [UUID: Waiter] = [:]
    /// Stopped for an embedder swap: on cancellation the waiters move to the next run instead of failing.
    var transferOnCancel = false

    var cancelled: Bool { control.isCancelled }
    var task: Task<Void, Never>? { control.task }

    init(id: Int, options: PassOptions) {
      self.id = id
      self.options = options
    }
  }

  private var current: Run?
  private var queued: Run?
  /// Preview rows whose full image didn't come in an upgrade pass, and how often, during this launch.
  private var failedUpgrades: [String: Int] = [:]
  private var holdQueued = false
  /// A swap's catch-up waiting for a limited run that callers were carried over to (see `performSwap`).
  private var deferredCatchUp = false
  private var lastRunId = 0

  public private(set) var progress = IndexProgress(runId: 0, processed: 0, total: 0, phase: .idle)
  private var observers: [UUID: AsyncStream<IndexProgress>.Continuation] = [:]

  /// `embedder` needs `vectors`, opened with the embedder's revision and dimensions. `vectors` alone (a
  /// store already open at the last revision while the model loads) is used only to purge stale
  /// vectors; `setEmbedder` replaces it.
  public init(library: any LibrarySource, signals: any SignalSource, repo: any IndexRepository,
              thermal: ThermalGate = ThermalGate(), embedder: (any Embedder)? = nil, vectors: (any VectorSink)? = nil,
              config: IndexerConfig = IndexerConfig()) throws(IndexerError) {
    self.library = library
    self.signals = signals
    self.repo = repo
    self.thermal = thermal
    self.config = config
    if let embedder {
      guard let vectors else { throw .missingVectorStore }
      try Self.validate(embedder, vectors)
      embedding = Embedding(embedder: embedder, vectors: vectors, generation: 0)
    } else {
      standingVectors = vectors
    }
  }

  /// Where purges go: the attached embedder's store, else a store open without one.
  private var purgeSink: (any VectorSink)? { embedding?.vectors ?? standingVectors }

  private static func validate(_ embedder: any Embedder, _ vectors: any VectorSink) throws(IndexerError) {
    guard embedder.revision == vectors.revision, embedder.dimensions == vectors.dimensions else {
      throw .embedderMismatch(embedder: embedder.revision, vectors: vectors.revision)
    }
  }

  public var hasEmbedder: Bool { embedding != nil }

  // MARK: - Embedder

  /// Attaches (or replaces) the embedder. The Indexer owns the ordering:
  /// 1. stops the active run (its callers carry over to the run after the swap);
  /// 2. drains: vectors buffered for the old embedder are written if the revision is unchanged and
  ///    dropped otherwise (the old index is about to be discarded), and earlier writes must succeed;
  ///    if the drain fails, the old embedder stays and the error is thrown;
  /// 3. calls `openVectors(revision, dimensions)` for the new embedder's store (for a new revision,
  ///    opening `VectorStore` wipes the old file and clears every `embedded` flag);
  /// 4. starts the catch-up run: assets with signals done but no vector are embedded without
  ///    recomputing signals, and vectors of deleted assets are purged.
  /// If `openVectors` throws or returns a store for another revision, no embedder is attached ("search
  /// unavailable") and the error is thrown.
  public func setEmbedder(_ embedder: any Embedder,
                          openVectors: @escaping @Sendable (_ revision: String, _ dimensions: Int) async throws -> any VectorSink)
    async throws {
    let previous = swapChain
    let task = Task<Void, Error> {
      _ = await previous?.result
      try await self.performSwap(embedder, openVectors: openVectors)
    }
    swapChain = task
    try await task.value
  }

  private func performSwap(_ embedder: any Embedder,
                           openVectors: @Sendable (String, Int) async throws -> any VectorSink) async throws {
    holdQueued = true
    defer {
      holdQueued = false
      startQueuedIfIdle()
    }
    let old = embedding
    let sameRevision = old.map { $0.embedder.revision == embedder.revision && $0.embedder.dimensions == embedder.dimensions } ?? false
    if !sameRevision {
      // Vectors for the old revision would land in an index that is about to be wiped: drop them, and
      // make any asset still in flight drop its vector too.
      generation += 1
      embedding = nil
      vectorBuffer = nil
    }
    if let run = current {
      run.transferOnCancel = true
      stop(run)
      await run.task?.value
    }
    do {
      try await flush()
    } catch {
      embedding = old
      throw error
    }
    embedding = nil
    standingVectors = nil  // never written again once the new store may be open on the same file
    generation += 1
    reservedCapacity = 0
    let vectors = try await openVectors(embedder.revision, embedder.dimensions)
    try Self.validate(embedder, vectors)
    embedding = Embedding(embedder: embedder, vectors: vectors, generation: generation)
    // Callers carried over from a limited run (the taste scan's `run(limit: 500)`) get that run back first: merging
    // the unlimited catch-up into it would make them wait for the whole library. The catch-up follows it.
    if let queued, queued.options.limit != nil, !queued.waiters.isEmpty {
      deferredCatchUp = true
    } else {
      startCatchUp()
    }
  }

  private func startCatchUp() {
    let catchUp = enlist(PassOptions(allowNetwork: false, limit: nil))
    catchUp.control.keepAlive()
  }

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

  private func enqueueLibraryChange(_ operation: @escaping @Sendable (Indexer) async throws -> SyncReport)
    async throws -> SyncReport {
    let previous = libraryChain
    let task = Task<SyncReport, Error> {
      _ = await previous?.result
      return try await operation(self)
    }
    libraryChain = task
    return try await task.value
  }

  private func performSync() async throws -> SyncReport {
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

  private func performApply(_ change: LibraryChange) async throws -> SyncReport {
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
  private func store(_ snapshots: [AssetSnapshot], known refs: [AssetRef]) async throws -> (inserted: Int, updated: Int) {
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
  private func purgeDeletedVectors() async throws {
    guard let sink = purgeSink else { return }
    let ids = try await repo.deletedEmbeddedIds()
    guard !ids.isEmpty else { return }
    dropBuffered(ids: Set(ids))
    try await enqueuePurge(clearing: ids, removing: ids, sink: sink)
  }

  private func dropBuffered(ids: Set<String>) {
    signalBuffer.removeAll { ids.contains($0.id) }
    vectorBuffer?.items.removeAll { ids.contains($0.id) }
  }

  // MARK: - Runs

  /// Work a local run would still do: pending assets (cloud-only ones wait for a network run, assets
  /// with too many failed loads are left out) minus vectors already computed and waiting for a flush.
  /// `includingEmbedding` defaults to whether an embedder is attached; pass `true` to count embedding
  /// work even without one (a background launch before the model has loaded).
  public func pendingCount(includingEmbedding: Bool? = nil) async throws -> Int {
    let withEmbedding = includingEmbedding ?? (embedding != nil)
    let count = try await repo.pendingAssetCount(includingEmbedding: withEmbedding, includingCloudOnly: false)
    let buffered = withEmbedding ? (vectorBuffer?.items.count ?? 0) : 0
    return max(0, count - buffered)
  }

  /// Indexes pending assets, newest first: at most `limit` per pass (nil: all), and with `allowNetwork`
  /// (Wi-Fi only; the app decides) cloud-only assets are fetched from iCloud. Joins the active run (see
  /// the type docs). Throws `CancellationError` when the caller is cancelled or the run is stopped.
  ///
  /// `upgradePreviews` (with `allowNetwork`; the opt-in "Improve with iCloud originals", on Wi-Fi while charging)
  /// also re-analyses rows that were analysed from a local preview, from full images downloaded from iCloud.
  @discardableResult
  public func run(limit: Int? = nil, allowNetwork: Bool = false, upgradePreviews: Bool = false) async throws -> IndexReport {
    try Task.checkCancellation()
    let run = enlist(PassOptions(allowNetwork: allowNetwork, limit: limit, upgradePreviews: upgradePreviews && allowNetwork))
    let waiter = UUID()
    let ticket = WaiterTicket(run.control)
    run.control.join()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        run.waiters[waiter] = Waiter(continuation: continuation, ticket: ticket)
      }
    } onCancel: {
      // Synchronously: the run stops at once if this was its last caller.
      ticket.leave()
      Task { await self.waiterCancelled(waiter) }
    }
  }

  /// Hard stop: cancels the active run (it flushes completed work first) and drops any queued one, including a swap's
  /// deferred catch-up (the next `run()` does that work).
  public func cancel() {
    deferredCatchUp = false
    if let queued {
      self.queued = nil
      queued.control.stop()
      for waiter in queued.waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
    }
    if let current {
      current.transferOnCancel = false
      stop(current)
    }
  }

  /// Returns once no run, swap, library change or write is in flight.
  public func waitUntilIdle() async {
    while true {
      let swap = swapChain
      let change = libraryChain
      let write = lastWrite
      _ = await swap?.result
      _ = await change?.result
      await current?.task?.value
      _ = await write?.result
      if swap == swapChain, change == libraryChain, write == lastWrite, current == nil { return }
    }
  }

  private func enlist(_ options: PassOptions) -> Run {
    if let current, !current.cancelled {
      current.morePass = current.morePass.map { $0.merged(with: options) } ?? options
      return current
    }
    if let queued {
      queued.options = queued.options.merged(with: options)
      return queued
    }
    lastRunId += 1
    let run = Run(id: lastRunId, options: options)
    if current == nil && !holdQueued {
      start(run)
    } else {
      queued = run
    }
    return run
  }

  private func start(_ run: Run) {
    current = run
    let runId = run.id
    run.control.setTask(Task { await self.execute(runId) })
  }

  private func startQueuedIfIdle() {
    guard current == nil, !holdQueued, let run = queued else { return }
    queued = nil
    start(run)
  }

  private func stop(_ run: Run) {
    run.control.stop()
  }

  /// The caller already left the run's control (which stopped the run if it was the last); this resumes it.
  private func waiterCancelled(_ id: UUID) {
    for run in [current, queued].compactMap({ $0 }) {
      if let waiter = run.waiters.removeValue(forKey: id) {
        waiter.continuation.resume(throwing: CancellationError())
        if run !== current, run.waiters.isEmpty, run.cancelled { queued = nil }
        return
      }
    }
  }

  private struct RunState {
    var report = IndexReport()
    /// Ids handled in this run; later passes skip them (except cloud-only ones on a network pass).
    var done: Set<String> = []
    var cloudSkipped: Set<String> = []
    /// Preview rows this pass re-analyses from full images.
    var upgrading: Set<String> = []
    var sinceVectorFlush = 0
  }

  private func execute(_ runId: Int) async {
    guard let run = current, run.id == runId else { return }
    publish(IndexProgress(runId: runId, processed: 0, total: 0, phase: .started))
    var state = RunState()
    var options = run.options
    let result: Result<IndexReport, Error>
    do {
      try await purgeDeletedVectors()
      while true {
        try await pass(options, runId: runId, state: &state)
        guard let more = run.morePass else { break }
        run.morePass = nil
        options = more
      }
      try await finishRun(newVectors: state.report.embedded)
      result = .success(state.report)
    } catch {
      // Keep what is complete. Writes run in their own task, so they aren't cancelled with this one.
      do { try await flush() } catch {
        IndexerLog.logger.error("flush after an interrupted run failed: \(String(describing: error))")
      }
      result = .failure(error)
    }
    let phase: IndexProgress.Phase = switch result {
    case .success: .finished
    case .failure(let error): error is CancellationError ? .cancelled : .failed
    }
    publish(IndexProgress(runId: runId, processed: progress.processed, total: progress.total, phase: phase))
    complete(run, result)
  }

  private func complete(_ run: Run, _ result: Result<IndexReport, Error>) {
    current = nil
    if run.transferOnCancel, case .failure(let error) = result, error is CancellationError {
      let next = enlist(run.options.merged(with: run.morePass ?? run.options))
      for (id, waiter) in run.waiters {
        waiter.ticket.move(to: next.control)
        next.waiters[id] = waiter
      }
      if run.control.keepsAlive { next.control.keepAlive() }
    } else {
      for waiter in run.waiters.values { waiter.continuation.resume(with: result) }
      if case .failure(let error) = result, !(error is CancellationError), run.waiters.isEmpty {
        IndexerLog.logger.error("index run failed: \(String(describing: error))")
      }
      if deferredCatchUp {
        deferredCatchUp = false
        startCatchUp()
      }
    }
    startQueuedIfIdle()
  }

  private func finishRun(newVectors: Int) async throws {
    let saveDue = lastSave.map { ContinuousClock.now - $0 >= config.minimumSaveInterval } ?? true
    if newVectors >= config.vectorFlushEvery || saveDue {
      try await flush()
    } else {
      try await commitSignals()
    }
  }

  private func pass(_ options: PassOptions, runId: Int, state: inout RunState) async throws {
    try Task.checkCancellation()
    state.report.passes += 1
    var ids = try await repo.pendingAssetIds(includingEmbedding: embedding != nil, includingCloudOnly: options.allowNetwork)
    state.upgrading = []
    if options.upgradePreviews {
      let pending = Set(ids)
      let previews = try await repo.previewAssetIds().filter {
        !pending.contains($0) && !state.done.contains($0) && failedUpgrades[$0, default: 0] < Self.maxUpgradeAttempts
      }
      state.upgrading = Set(previews)
      ids += previews
    }
    let buffered = Set(vectorBuffer?.items.map(\.id) ?? []).union(signalBuffer.map(\.id))
    let skip = options.allowNetwork ? state.done.subtracting(state.cloudSkipped) : state.done
    ids.removeAll { skip.contains($0) || buffered.contains($0) }
    if let limit = options.limit { ids = Array(ids.prefix(max(0, limit))) }
    publish(IndexProgress(runId: runId, processed: 0, total: ids.count, phase: .indexing))
    guard !ids.isEmpty else { return }
    await reserveIfLarge(incoming: ids.count)

    for start in stride(from: 0, to: ids.count, by: config.pageSize) {
      try Task.checkCancellation()
      let pageIds = Array(ids[start..<min(start + config.pageSize, ids.count)])
      let records = try await repo.assets(ids: pageIds)
      signals.refreshPolicy()
      try await process(records, allowNetwork: options.allowNetwork, runId: runId, base: start, total: ids.count,
                        state: &state)
      state.done.formUnion(pageIds)
      state.sinceVectorFlush += pageIds.count
      if state.sinceVectorFlush >= config.vectorFlushEvery {
        try await flush()
        state.sinceVectorFlush = 0
      } else {
        try await commitSignals()
      }
    }
  }

  private func reserveIfLarge(incoming: Int) async {
    guard let embedding else { return }
    let stored = await embedding.vectors.count
    let needed = stored + incoming
    guard incoming > max(config.reserveThreshold, stored / 10), needed > reservedCapacity else { return }
    await embedding.vectors.reserve(needed)
    reservedCapacity = needed
  }

  /// One page, in thumbnail groups: the next group loads while this one goes through Vision and the
  /// embedder, one asset at a time.
  private func process(_ records: [AssetRecord], allowNetwork: Bool, runId: Int, base: Int, total: Int,
                       state: inout RunState) async throws {
    var processed = base
    let work = records.filter { needsWork($0) || isUpgrade($0, state) }
    // Rows that need nothing any more (handled since the snapshot) count as processed.
    state.report.processed += records.count - work.count
    processed += records.count - work.count
    let groups = stride(from: 0, to: work.count, by: config.thumbnailChunk).map {
      Array(work[$0..<min($0 + config.thumbnailChunk, work.count)])
    }
    var next = groups.first.map { loadThumbnails($0, allowNetwork: allowNetwork) }
    for group in groups.indices {
      guard let current = next else { break }
      let loaded = await withTaskCancellationHandler { await current.value } onCancel: { current.cancel() }
      let thumbnails = loaded.results
      next = group + 1 < groups.count ? loadThumbnails(groups[group + 1], allowNetwork: allowNetwork) : nil
      do {
        for record in groups[group] {
          try Task.checkCancellation()
          try await index(record, thumbnail: thumbnails[record.id] ?? .failed,
                          downloaded: loaded.downloaded.contains(record.id), runId: runId, state: &state)
          state.report.processed += 1
          processed += 1
          publish(IndexProgress(runId: runId, processed: processed, total: total, phase: .indexing))
        }
      } catch {
        next?.cancel()
        throw error
      }
    }
  }

  private func isUpgrade(_ record: AssetRecord, _ state: RunState) -> Bool {
    !record.deleted && record.source == .preview && state.upgrading.contains(record.id)
  }

  private func needsWork(_ record: AssetRecord) -> Bool {
    !record.deleted && (!record.signalsDone || (embedding != nil && !record.embedded))
  }

  /// Thumbnails for a group, and which of them came from a download.
  private struct Loaded: Sendable {
    var results: [String: ThumbnailResult] = [:]
    var downloaded: Set<String> = []
  }

  /// Always asks with network access off first: that answer is the only evidence of where an original is. With
  /// `allowNetwork`, what didn't come back as a full image is then requested again with the network; a full image from
  /// that second request is a download (`downloaded`). If the download fails, an offline preview still counts.
  private nonisolated func loadThumbnails(_ records: [AssetRecord], allowNetwork: Bool) -> Task<Loaded, Never> {
    let library = library
    let side = config.thumbnailSide
    let fraction = config.videoFrameFraction
    let photos = records.filter { $0.mediaType != MediaKind.video }.map(\.id)
    let videos = records.filter { $0.mediaType == MediaKind.video }.map(\.id)
    @Sendable func fetch(_ photos: [String], _ videos: [String], network: Bool) async -> [String: ThumbnailResult] {
      var results = photos.isEmpty ? [:] : await library.thumbnails(ids: photos, side: side, allowNetwork: network)
      for id in videos {
        results[id] = Task.isCancelled
          ? .cancelled : await library.videoFrame(id: id, at: fraction, side: side, allowNetwork: network)
      }
      return results
    }
    return Task {
      var loaded = Loaded(results: await fetch(photos, videos, network: false))
      guard allowNetwork, !Task.isCancelled else { return loaded }
      func needsDownload(_ id: String) -> Bool {
        switch loaded.results[id] {
        case .image?, .cancelled?: false
        default: true
        }
      }
      let retry = (photos.filter(needsDownload), videos.filter(needsDownload))
      guard !retry.0.isEmpty || !retry.1.isEmpty else { return loaded }
      for (id, result) in await fetch(retry.0, retry.1, network: true) {
        if case .image = result {
          loaded.results[id] = result
          loaded.downloaded.insert(id)
        } else if loaded.results[id]?.isPreview != true {
          loaded.results[id] = result  // keep an offline preview over a failed download
        }
      }
      return loaded
    }
  }

  private func index(_ record: AssetRecord, thumbnail: ThumbnailResult, downloaded: Bool, runId: Int,
                     state: inout RunState) async throws {
    let target = embedding
    let upgrade = isUpgrade(record, state)
    if upgrade, !(thumbnail.image != nil && !thumbnail.isPreview) {
      // The full image didn't come (still only the preview, or failed): keep the row as it is.
      if case .cancelled = thumbnail, Task.isCancelled { throw CancellationError() }
      failedUpgrades[record.id, default: 0] += 1  // our own cancel above isn't an attempt
      return
    }
    let needsSignals = !record.signalsDone || upgrade
    let needsVector = target != nil && (!record.embedded || upgrade)

    let image: CGImage
    let fromPreview: Bool
    switch thumbnail {
    case .cancelled where Task.isCancelled:
      throw CancellationError()  // our own cancellation: stop, record nothing
    case .failed, .cancelled:
      // A cancel we didn't ask for (PhotoKit gave up) is a failed load like any other.
      state.report.failed += 1
      failureBuffer.append(record.id)
      return
    case .inCloud:
      state.report.cloudOnly += 1
      state.cloudSkipped.insert(record.id)
      signalBuffer.append(SignalFields(keeping: record, cloudOnly: true))
      return
    case .image(let cgImage):
      image = cgImage
      fromPreview = false
    case .preview(let cgImage):
      image = cgImage
      fromPreview = true
    }
    // Where the original is, from the offline request only: a preview or a download means iCloud; a full image that
    // came without the network means this iPhone.
    let cloudOnly = fromPreview || downloaded
    let source: AnalysisSource = fromPreview ? .preview : .full
    let previewSide = max(image.width, image.height)  // the analysed image's size, preview or full

    if thermal.isThrottled {
      publish(IndexProgress(runId: runId, processed: progress.processed, total: progress.total, phase: .thermalPause))
      state.report.thermalPolls += try await thermal.waitUntilOK()
      publish(IndexProgress(runId: runId, processed: progress.processed, total: progress.total, phase: .indexing))
    }

    let signals = signals
    async let computed = Self.extract(signals, image, if: needsSignals)
    async let vector = Self.embed(target?.embedder, image, if: needsVector)
    let embedded = await vector
    let fields = try await computed
    try Task.checkCancellation()  // a cancelled asset is discarded whole

    if let fields {
      state.report.signalsComputed += 1
      if fromPreview { state.report.previews += 1 }
      if upgrade { state.report.upgraded += 1 }
      signalBuffer.append(SignalFields(id: record.id, computed: fields, cloudOnly: cloudOnly, source: source,
                                       previewSide: previewSide))
    } else if record.cloudOnly != cloudOnly {
      signalBuffer.append(SignalFields(keeping: record, cloudOnly: cloudOnly))
    }
    switch embedded {
    case .vector(let values):
      // Dropped if the embedder was swapped meanwhile: it belongs to the old index.
      guard let target, target.generation == embedding?.generation else { break }
      guard values.count == target.vectors.dimensions else {
        IndexerLog.logger.error("embedder returned \(values.count) values, expected \(target.vectors.dimensions)")
        state.report.embedFailures += 1
        break
      }
      state.report.embedded += 1
      if vectorBuffer == nil { vectorBuffer = VectorBatch(generation: target.generation, sink: target.vectors, items: []) }
      vectorBuffer?.items.append((id: record.id, vector: values))
    case .failed:
      state.report.embedFailures += 1
    case .skipped:
      break
    }
  }

  private enum EmbedOutcome: Sendable {
    case vector([Float]), failed, skipped
  }

  private static func extract(_ source: any SignalSource, _ image: CGImage, if needed: Bool)
    async throws(CancellationError) -> AssetSignals? {
    guard needed else { return nil }
    return try await source.extract(image)
  }

  private static func embed(_ embedder: (any Embedder)?, _ image: CGImage, if needed: Bool) async -> EmbedOutcome {
    guard needed, let embedder else { return .skipped }
    do {
      return .vector(try await embedder.embed(image: image))
    } catch {
      if !Task.isCancelled { IndexerLog.logger.error("embedding failed: \(String(describing: error))") }
      return .failed
    }
  }

  // MARK: - Writes

  /// Writes everything buffered: signals and failed loads, then vectors (`upsert` → `save()` →
  /// `markEmbedded`). Waits for earlier writes and fails if one of them failed (their data is back in
  /// the buffers, so calling again retries it). Returning normally means everything computed before the
  /// call is on disk. Safe during a run; the app calls it when going to the background.
  public func flush() async throws {
    let batch = WriteBatch(signals: signalBuffer, failures: failureBuffer, vectors: vectorBuffer)
    signalBuffer = []
    failureBuffer = []
    vectorBuffer = nil
    try await enqueue(batch)
  }

  /// Signals and failed loads only; vectors stay buffered.
  private func commitSignals() async throws {
    let batch = WriteBatch(signals: signalBuffer, failures: failureBuffer, vectors: nil)
    signalBuffer = []
    failureBuffer = []
    try await enqueue(batch)
  }

  private struct WriteBatch: Sendable {
    var signals: [SignalFields]
    var failures: [String]
    var vectors: VectorBatch?

    var isEmpty: Bool { signals.isEmpty && failures.isEmpty && (vectors?.items.isEmpty ?? true) }
  }

  /// Serialises writes: each starts after the previous one and fails if it failed. Runs in an
  /// unstructured task so a cancelled run can still commit what it finished. On failure, the parts that
  /// did not land go back into the buffers.
  private func enqueue(_ batch: WriteBatch) async throws {
    let previous = lastWrite
    guard !batch.isEmpty else {
      try await previous?.value
      return
    }
    let repo = repo
    let stage = WriteStage()
    let task = Task<Void, Error> {
      try await previous?.value
      if !batch.signals.isEmpty { try await repo.commitSignals(batch.signals) }
      stage.reached(1)
      if !batch.failures.isEmpty { try await repo.recordFailedAttempts(ids: batch.failures) }
      stage.reached(2)
      if let vectors = batch.vectors, !vectors.items.isEmpty {
        try await vectors.sink.upsert(vectors.items)
        try await vectors.sink.save()
        try await repo.markEmbedded(ids: vectors.items.map(\.id))
      }
    }
    lastWrite = task
    do {
      try await task.value
      if !(batch.vectors?.items.isEmpty ?? true) { lastSave = .now }
    } catch {
      if lastWrite == task { lastWrite = nil }
      let reached = stage.value
      if reached < 1 { signalBuffer = batch.signals + signalBuffer }
      if reached < 2 { failureBuffer = batch.failures + failureBuffer }
      if let vectors = batch.vectors, vectors.generation == embedding?.generation {
        if var buffered = vectorBuffer {
          buffered.items = vectors.items + buffered.items
          vectorBuffer = buffered
        } else {
          vectorBuffer = vectors
        }
      }
      throw error
    }
  }

  /// Clears `clearing` flags, removes `removing` vectors, saves: in that order, so a crash leaves at
  /// worst a vector with no flag. Queued behind other writes (but not failed by them).
  private func enqueuePurge(clearing: [String], removing: [String], sink: any VectorSink) async throws {
    let previous = lastWrite
    let repo = repo
    let task = Task<Void, Error> {
      _ = await previous?.result
      if !clearing.isEmpty { _ = try await repo.clearEmbedded(ids: clearing) }
      try await sink.remove(ids: removing)
      try await sink.save()
    }
    lastWrite = task
    do {
      try await task.value
      lastSave = .now
    } catch {
      if lastWrite == task { lastWrite = nil }
      throw error
    }
  }

  // MARK: - Progress

  /// A stream of progress updates. It starts with the active run's state, or `.idle` (carrying the last
  /// run's id) when nothing is running, never a finished state from an earlier run. Slow readers see the
  /// latest value.
  public func progressUpdates() -> AsyncStream<IndexProgress> {
    let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    observers[id] = continuation
    if current != nil || progress.phase == .syncing {
      continuation.yield(progress)
    } else {
      continuation.yield(IndexProgress(runId: progress.runId, processed: 0, total: 0, phase: .idle))
    }
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    return stream
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  private func publish(phase: IndexProgress.Phase) {
    publish(IndexProgress(runId: progress.runId, processed: 0, total: 0, phase: phase))
  }

  private func publish(_ update: IndexProgress) {
    progress = update
    for continuation in observers.values { continuation.yield(update) }
  }
}

/// Thread-safe run bookkeeping that cancellation handlers can reach without hopping to the actor:
/// how many callers wait, whether the Indexer itself keeps the run alive, and its task.
private final class RunControl: Sendable {
  private let state = Mutex<(waiters: Int, keepAlive: Bool, cancelled: Bool, task: Task<Void, Never>?)>((0, false, false, nil))

  var isCancelled: Bool { state.withLock { $0.cancelled } }
  var keepsAlive: Bool { state.withLock { $0.keepAlive } }
  var task: Task<Void, Never>? { state.withLock { $0.task } }

  func join() { state.withLock { $0.waiters += 1 } }
  func keepAlive() { state.withLock { $0.keepAlive = true } }

  func setTask(_ task: Task<Void, Never>) {
    let cancelNow = state.withLock { s in
      s.task = task
      return s.cancelled
    }
    if cancelNow { task.cancel() }
  }

  /// One caller stopped waiting; the last one (unless kept alive) stops the run.
  func leave() {
    let task: Task<Void, Never>?? = state.withLock { s in
      s.waiters = max(0, s.waiters - 1)
      guard s.waiters == 0, !s.keepAlive, !s.cancelled else { return .none }
      s.cancelled = true
      return .some(s.task)
    }
    if case .some(let task) = task { task?.cancel() }
  }

  func stop() {
    let task = state.withLock { s in
      s.cancelled = true
      return s.task
    }
    task?.cancel()
  }
}

/// Which run a caller is waiting on; moved when an embedder swap carries callers over to the next run.
private final class WaiterTicket: Sendable {
  private let control: Mutex<RunControl>

  init(_ control: RunControl) { self.control = Mutex(control) }

  func move(to next: RunControl) {
    control.withLock { $0 = next }
    next.join()
  }

  func leave() { control.withLock { $0 }.leave() }
}

/// How far a write got before failing (signals 1, failed loads 2), so only the rest is re-buffered.
private final class WriteStage: Sendable {
  private let stage = Mutex(0)
  func reached(_ value: Int) { stage.withLock { $0 = value } }
  var value: Int { stage.withLock { $0 } }
}

extension AssetRecord {
  /// A library row for `upsertAssets`; computed columns keep their defaults (the upsert never overwrites them).
  init(_ snapshot: AssetSnapshot, estBytes: Int64) {
    self.init(id: snapshot.id, mediaType: snapshot.mediaType, subtypes: snapshot.subtypes, created: snapshot.created,
              pixelW: snapshot.pixelW, pixelH: snapshot.pixelH, duration: snapshot.duration,
              isFavorite: snapshot.isFavorite, burstId: snapshot.burstId, uti: snapshot.uti, estBytes: estBytes,
              modified: snapshot.modified)
  }
}

extension SignalFields {
  init(id: String, computed s: AssetSignals, cloudOnly: Bool, source: AnalysisSource, previewSide: Int?) {
    self.init(id: id, signalsDone: true, blur: s.blur.map(Double.init), aesthetic: s.aesthetic.map(Double.init),
              isUtility: s.isUtility, sensitive: s.sensitive, phash: s.phash, featurePrint: s.featurePrint,
              cloudOnly: cloudOnly, source: source, previewSide: previewSide)
  }

  /// The row's current signals with a new `cloudOnly` flag (`commitSignals` writes every signal column).
  init(keeping record: AssetRecord, cloudOnly: Bool) {
    self.init(id: record.id, signalsDone: record.signalsDone, blur: record.blur, aesthetic: record.aesthetic,
              isUtility: record.isUtility, sensitive: record.sensitive, phash: record.phash,
              featurePrint: record.featurePrint, cloudOnly: cloudOnly, source: record.source,
              previewSide: record.previewSide)
  }
}
