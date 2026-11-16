import CoreGraphics
import Embedding
import Foundation
import Library
import os
import Signals
import Store
import Synchronization

extension Indexer {
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

  func enlist(_ options: PassOptions) -> Run {
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

  func start(_ run: Run) {
    current = run
    let runId = run.id
    run.control.setTask(Task { await self.execute(runId) })
  }

  func startQueuedIfIdle() {
    guard current == nil, !holdQueued, let run = queued else { return }
    queued = nil
    start(run)
  }

  func stop(_ run: Run) {
    run.control.stop()
  }

  /// The caller already left the run's control (which stopped the run if it was the last); this resumes it.
  func waiterCancelled(_ id: UUID) {
    for run in [current, queued].compactMap({ $0 }) {
      if let waiter = run.waiters.removeValue(forKey: id) {
        waiter.continuation.resume(throwing: CancellationError())
        if run !== current, run.waiters.isEmpty, run.cancelled { queued = nil }
        return
      }
    }
  }

  struct RunState {
    var report = IndexReport()
    /// Ids handled in this run; later passes skip them (except cloud-only ones on a network pass).
    var done: Set<String> = []
    var cloudSkipped: Set<String> = []
    /// Preview rows this pass re-analyses from full images.
    var upgrading: Set<String> = []
    var sinceVectorFlush = 0
  }

  func execute(_ runId: Int) async {
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

  func complete(_ run: Run, _ result: Result<IndexReport, Error>) {
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

  func finishRun(newVectors: Int) async throws {
    let saveDue = lastSave.map { ContinuousClock.now - $0 >= config.minimumSaveInterval } ?? true
    if newVectors >= config.vectorFlushEvery || saveDue {
      try await flush()
    } else {
      try await commitSignals()
    }
  }

  func pass(_ options: PassOptions, runId: Int, state: inout RunState) async throws {
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
}
