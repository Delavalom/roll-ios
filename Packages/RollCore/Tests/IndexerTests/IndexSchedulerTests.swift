import Foundation
import Store
import Synchronization
import Testing
@testable import Indexer

/// Stands in for a `BGProcessingTask`: captures the expiration handler and the completion.
final class FakeBackgroundTask: Sendable {
  private let state = Mutex<(expiration: (@Sendable () -> Void)?, completed: [Bool], reschedules: Int)>((nil, [], 0))

  var completed: [Bool] { state.withLock { $0.completed } }
  var reschedules: Int { state.withLock { $0.reschedules } }

  func setExpiration(_ handler: @escaping @Sendable () -> Void) { state.withLock { $0.expiration = handler } }
  func expire() { state.withLock { $0.expiration }?() }
  func complete(_ success: Bool) { state.withLock { $0.completed.append(success) } }
  func reschedule() { state.withLock { $0.reschedules += 1 } }
}

struct IndexSchedulerTests {
  @Test func usesTheRegisteredIdentifier() {
    #expect(IndexScheduler.taskIdentifier == "com.delavalom.roll.index")
  }

  @Test func aCompleteRunSucceedsAndDoesNotReschedule() async throws {
    try await Harness.with(count: 30) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let bg = FakeBackgroundTask()
      let work = IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                                        reschedule: bg.reschedule, complete: bg.complete)
      await work.value
      #expect(bg.completed == [true])
      #expect(bg.reschedules == 0)
      #expect(try await h.count("embedded = 1") == 30)
    }
  }

  @Test func expirationCancelsFlushesAndReschedules() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let bg = FakeBackgroundTask()
      // Expire mid-run, from inside the pipeline (as the system would, on its own thread).
      h.signals.onExtract.withLock { $0 = { n in if n == 120 { bg.expire() } } }
      let work = IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                                        reschedule: bg.reschedule, complete: bg.complete)
      await work.value
      #expect(bg.completed == [false])
      #expect(bg.reschedules == 1)
      #expect(try await h.count("embedded = 1") == 119)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func noIndexerYetCompletesAsFailedAndReschedules() async {
    let bg = FakeBackgroundTask()
    let work = IndexScheduler.perform(indexer: { nil }, setExpirationHandler: bg.setExpiration,
                                      reschedule: bg.reschedule, complete: bg.complete)
    await work.value
    #expect(bg.completed == [false])
    #expect(bg.reschedules == 1)
  }

  @Test func expirationStopsEvenARunTheIndexerKeepsAlive() async throws {
    try await Harness.with(count: 20, hotReads: .max) { h in
      let indexer = try h.indexer(embedder: false, pollInterval: .milliseconds(1))
      try await indexer.sync()
      // Signals-only would also wait on the thermal gate; mark signals done directly instead.
      try await h.repo.commitSignals((0..<20).map { SignalFields(id: FakeLibrary.id($0), signalsDone: true) })
      try await indexer.setEmbedder(Harness.embedder, openVectors: h.openSameStore)  // catch-up, kept alive
      try await Harness.waitUntil { await indexer.progress.phase == .thermalPause }
      let bg = FakeBackgroundTask()
      IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                             reschedule: bg.reschedule, complete: bg.complete)
      try await Task.sleep(for: .milliseconds(5))
      bg.expire()
      try await Harness.waitUntil { bg.completed.count == 1 }
      #expect(bg.completed == [false])
      #expect(bg.reschedules == 1)
      try await Harness.waitUntil { await indexer.progress.phase == .cancelled }
      await indexer.cancel()  // so a regression fails here instead of hanging
      await indexer.waitUntilIdle()
    }
  }

  @Test func expirationWhileWaitingForAThumbnailRecordsNoFailure() async throws {
    try await Harness.with(count: 60, videoEvery: nil) { h in
      let stuck = FakeLibrary.id(20)
      h.library.set(.hang, for: [stuck])
      let indexer = try h.indexer()
      try await indexer.sync()
      let bg = FakeBackgroundTask()
      let work = IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                                        reschedule: bg.reschedule, complete: bg.complete)
      try await Harness.waitUntil { h.library.state.withLock { $0.hangEntered } }
      bg.expire()
      await work.value
      #expect(bg.completed == [false])
      #expect(bg.reschedules == 1)
      let row = try #require(try await h.repo.asset(id: stuck))
      #expect(row.attempts == 0 && !row.signalsDone)
      // id 20 is in the third group of 8; it hangs while the second group is processed (prefetch).
      let done = try await h.count("embedded = 1")
      #expect(done >= 8 && done <= 16)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func expirationDuringAFlushLetsTheFlushFinish() async throws {
    try await Harness.with(count: 30) { h in
      let sink = ControlledSink(base: h.store, log: h.log)
      sink.gateOpen.withLock { $0 = false }
      let indexer = try h.indexer(vectors: sink)
      try await indexer.sync()
      let bg = FakeBackgroundTask()
      let work = IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                                        reschedule: bg.reschedule, complete: bg.complete)
      try await Harness.waitUntil { sink.saveEntered.withLock { $0 } }
      bg.expire()
      try await Task.sleep(for: .milliseconds(5))
      sink.gateOpen.withLock { $0 = true }
      await work.value
      #expect(bg.completed.count == 1)
      #expect(try await h.count("embedded = 1") == 30, "the save in progress completes and is flagged")
      #expect(await h.store.count == 30)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func goingToTheBackgroundFlushesStopsTheRunAndSchedules() async throws {
    try await Harness.with(count: 100) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let paused = Mutex(false)
      h.signals.onExtractAsync.withLock {
        $0 = { n in
          guard n == 10 else { return }
          paused.withLock { $0 = true }
          while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        }
      }
      let foreground = Task { try await indexer.run() }
      try await Harness.waitUntil { paused.withLock { $0 } }
      let scheduled = Mutex(0)
      await IndexScheduler.prepareForBackground(indexer: indexer) { scheduled.withLock { $0 += 1 } }
      await #expect(throws: CancellationError.self) { try await foreground.value }
      #expect(scheduled.withLock { $0 } == 1)
      #expect(try await h.count("embedded = 1") == 9)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func aBackgroundLaunchWithoutAnEmbedderStillReschedulesForEmbeddingWork() async throws {
    try await Harness.with(count: 20) { h in
      let indexer = try h.indexer(embedder: false)
      try await indexer.sync()
      try await indexer.run()
      #expect(try await indexer.pendingCount() == 0)
      let bg = FakeBackgroundTask()
      await IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                                   reschedule: bg.reschedule, complete: bg.complete).value
      #expect(bg.completed == [true])
      #expect(bg.reschedules == 1, "20 assets still need vectors once the model loads")
    }
  }

  @Test func onlyFailedAssetsLeftStopsRescheduling() async throws {
    try await Harness.with(count: 10) { h in
      h.library.set(.failedAlways, for: [FakeLibrary.id(4)])
      let indexer = try h.indexer()
      try await indexer.sync()
      for _ in 0..<3 { try await indexer.run() }
      let bg = FakeBackgroundTask()
      await IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                                   reschedule: bg.reschedule, complete: bg.complete).value
      #expect(bg.completed == [true])
      #expect(bg.reschedules == 0)
    }
  }
}
