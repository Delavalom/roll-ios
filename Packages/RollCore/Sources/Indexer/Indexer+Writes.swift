import CoreGraphics
import Embedding
import Foundation
import Library
import os
import Signals
import Store
import Synchronization

extension Indexer {
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
  func commitSignals() async throws {
    let batch = WriteBatch(signals: signalBuffer, failures: failureBuffer, vectors: nil)
    signalBuffer = []
    failureBuffer = []
    try await enqueue(batch)
  }

  struct WriteBatch: Sendable {
    var signals: [SignalFields]
    var failures: [String]
    var vectors: VectorBatch?

    var isEmpty: Bool { signals.isEmpty && failures.isEmpty && (vectors?.items.isEmpty ?? true) }
  }

  /// Serialises writes: each starts after the previous one and fails if it failed. Runs in an
  /// unstructured task so a cancelled run can still commit what it finished. On failure, the parts that
  /// did not land go back into the buffers.
  func enqueue(_ batch: WriteBatch) async throws {
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
  func enqueuePurge(clearing: [String], removing: [String], sink: any VectorSink) async throws {
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

  func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  func publish(phase: IndexProgress.Phase) {
    publish(IndexProgress(runId: progress.runId, processed: 0, total: 0, phase: phase))
  }

  func publish(_ update: IndexProgress) {
    progress = update
    for continuation in observers.values { continuation.yield(update) }
  }
}
