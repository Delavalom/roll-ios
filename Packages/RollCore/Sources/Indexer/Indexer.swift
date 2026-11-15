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
  let library: any LibrarySource
  let signals: any SignalSource
  let repo: any IndexRepository
  let thermal: ThermalGate
  let config: IndexerConfig

  struct Embedding {
    let embedder: any Embedder
    let vectors: any VectorSink
    let generation: Int
  }

  var embedding: Embedding?
  /// A store opened without an embedder (the model hasn't loaded yet; the store is at the last revision).
  /// Nothing is embedded into it, but deleted and edited assets lose their stale vectors right away.
  var standingVectors: (any VectorSink)?
  var generation = 0
  var reservedCapacity = 0

  // Buffered writes.
  struct VectorBatch: Sendable {
    let generation: Int
    let sink: any VectorSink
    var items: [(id: String, vector: [Float])]
  }

  var signalBuffer: [SignalFields] = []
  var failureBuffer: [String] = []
  var vectorBuffer: VectorBatch?
  var lastWrite: Task<Void, Error>?
  var lastSave: ContinuousClock.Instant?

  // Serialised operations.
  var libraryChain: Task<SyncReport, Error>?
  var swapChain: Task<Void, Error>?

  // Runs.
  struct PassOptions: Sendable, Equatable {
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

  struct Waiter {
    let continuation: CheckedContinuation<IndexReport, Error>
    let ticket: WaiterTicket
  }

  final class Run {
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

  var current: Run?
  var queued: Run?
  /// Preview rows whose full image didn't come in an upgrade pass, and how often, during this launch.
  var failedUpgrades: [String: Int] = [:]
  var holdQueued = false
  /// A swap's catch-up waiting for a limited run that callers were carried over to (see `performSwap`).
  var deferredCatchUp = false
  var lastRunId = 0

  public internal(set) var progress = IndexProgress(runId: 0, processed: 0, total: 0, phase: .idle)
  var observers: [UUID: AsyncStream<IndexProgress>.Continuation] = [:]

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
  var purgeSink: (any VectorSink)? { embedding?.vectors ?? standingVectors }

  static func validate(_ embedder: any Embedder, _ vectors: any VectorSink) throws(IndexerError) {
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

  func performSwap(_ embedder: any Embedder,
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

  func startCatchUp() {
    let catchUp = enlist(PassOptions(allowNetwork: false, limit: nil))
    catchUp.control.keepAlive()
  }
}
