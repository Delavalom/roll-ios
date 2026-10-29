import Embedding
import Foundation
import GRDB
import Library
import Store
import Synchronization
import Testing
@testable import Indexer

/// Library whose `utis(for:)` blocks until `open`, so a test can hold a `sync()` mid-flight.
final class GatedLibrary: LibrarySource {
  let inner: FakeLibrary
  let open = Mutex(true)
  let entered = Mutex(false)
  init(_ inner: FakeLibrary) { self.inner = inner }
  /// The sync's library read takes its snapshot, then blocks while the gate is closed, so it returns a stale snapshot
  /// (syncs make no type lookups any more).
  func fetchAll() async -> [AssetSnapshot] {
    let snapshot = inner.fetchAll()
    entered.withLock { $0 = true }
    while !open.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
    return snapshot
  }
  func snapshots(ids: [String]) async -> [AssetSnapshot] { inner.snapshots(ids: ids) }
  func utis(for ids: [String]) async -> [String: String] { inner.utis(for: ids) }
  func thumbnails(ids: [String], side: Int, allowNetwork: Bool) async -> [String: ThumbnailResult] {
    await inner.thumbnails(ids: ids, side: side, allowNetwork: allowNetwork)
  }
  func videoFrame(id: String, at fraction: Double, side: Int, allowNetwork: Bool) async -> ThumbnailResult {
    await inner.videoFrame(id: id, at: fraction, side: side, allowNetwork: allowNetwork)
  }
}

/// Regression tests from the Indexer review: run coalescing, limits, embedder swaps, library-mutation
/// ordering, vector purges, write failures and progress.
struct IndexerConcurrencyTests {
  // MARK: I1 run coalescing

  @Test func oneWaiterCancellingLeavesTheOtherRunning() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let started = Mutex(false)
      h.signals.onExtract.withLock { $0 = { n in if n == 5 { started.withLock { $0 = true } } } }
      let owner = Task { try await indexer.run() }
      try await Harness.waitUntil { started.withLock { $0 } }
      let joiner = Task { try await indexer.run() }
      try await Task.sleep(for: .milliseconds(5))
      joiner.cancel()
      await #expect(throws: CancellationError.self) { try await joiner.value }
      let report = try await owner.value
      #expect(report.processed == 450)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 450)
    }
  }

  @Test func theLastWaiterCancellingStopsTheRun() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let started = Mutex(false)
      h.signals.onExtract.withLock { $0 = { n in if n == 5 { started.withLock { $0 = true } } } }
      let a = Task { try await indexer.run() }
      let b = Task { try await indexer.run() }
      try await Harness.waitUntil { started.withLock { $0 } }
      a.cancel()
      b.cancel()
      await #expect(throws: CancellationError.self) { try await a.value }
      await #expect(throws: CancellationError.self) { try await b.value }
      await indexer.waitUntilIdle()
      #expect(try await h.count("embedded = 1") < 450)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func joiningACancelledRunQueuesAFreshOne() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let first = Mutex<Task<IndexReport, any Error>?>(nil)
      let joined = Mutex<Task<IndexReport, any Error>?>(nil)
      h.signals.onExtract.withLock {
        $0 = { n in
          guard n == 50 else { return }
          first.withLock { $0 }?.cancel()
          joined.withLock { $0 = Task { try await indexer.run() } }
        }
      }
      let task = Task { try await indexer.run() }
      first.withLock { $0 = task }
      await #expect(throws: CancellationError.self) { try await task.value }
      try await Harness.waitUntil { joined.withLock { $0 } != nil }
      let report = try await joined.withLock { $0 }!.value
      #expect(report.processed == 451 - 50, "the queued run picks up everything the cancelled one left")
      #expect(try await indexer.pendingCount() == 0)
    }
  }

  @Test func allowNetworkIsKeptWhenJoiningALocalRun() async throws {
    try await Harness.with(count: 450) { h in
      let cloud = [FakeLibrary.id(400), FakeLibrary.id(401)]
      h.library.set(.inCloud, for: cloud)
      let indexer = try h.indexer()
      try await indexer.sync()
      let started = Mutex(false)
      h.signals.onExtract.withLock { $0 = { n in if n == 5 { started.withLock { $0 = true } } } }
      let local = Task { try await indexer.run() }
      try await Harness.waitUntil { started.withLock { $0 } }
      _ = try await indexer.run(allowNetwork: true)
      _ = try await local.value
      // Fetched over the network: analysed in full, but the originals are still in iCloud.
      #expect(try await h.count("cloudOnly = 1 AND source = 'full' AND signalsDone = 1") == 2)
      #expect(Set(h.library.state.withLock { $0.networkRequests }) == Set(cloud))
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 450)
    }
  }

  // MARK: I2 limit

  @Test func limitStopsAfterThatManyAssets() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let report = try await indexer.run(limit: 120)
      #expect(report.processed == 120)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 120)
      // Newest first.
      #expect(try await h.repo.asset(id: FakeLibrary.id(119))?.embedded == true)
      #expect(try await h.repo.asset(id: FakeLibrary.id(120))?.embedded == false)
      #expect(try await indexer.pendingCount() == 330)
    }
  }

  @Test func anUnlimitedCallerJoiningALimitedRunContinuesPastTheLimit() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let started = Mutex(false)
      h.signals.onExtract.withLock { $0 = { n in if n == 5 { started.withLock { $0 = true } } } }
      let limited = Task { try await indexer.run(limit: 50) }
      try await Harness.waitUntil { started.withLock { $0 } }
      let full = try await indexer.run()
      #expect(try await limited.value == full, "both callers see the whole run")
      #expect(full.processed == 450)
      #expect(try await indexer.pendingCount() == 0)
    }
  }

  // MARK: I3 embedder swap

  @Test func swappingTheEmbedderMidRunLeavesNoFlagWithoutAVector() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-swap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("v.egix")
    let library = FakeLibrary(count: 20)
    let db = try AppDatabase.inMemory()
    let a = StubEmbedder(dimensions: 8)
    let b = StubEmbedder(dimensions: 8, seed: 99)
    let storeA = try await VectorStore(url: url, dimensions: 8, revision: a.revision, database: db)
    let signals = FakeSignals()
    let indexer = try Indexer(library: library, signals: signals, repo: Repositories(db), embedder: a, vectors: storeA,
                              config: Harness.testConfig)
    try await indexer.sync()
    try await indexer.run()
    library.state.withLock { s in s.assets += (20..<40).map(FakeLibrary.snapshot) }
    try await indexer.sync()

    let storeB = Mutex<VectorStore?>(nil)
    let open: @Sendable (String, Int) async throws -> any VectorSink = { revision, dimensions in
      let store = try await VectorStore(url: url, dimensions: dimensions, revision: revision, database: db)
      storeB.withLock { $0 = store }
      return store
    }
    let swap = Mutex<Task<Void, any Error>?>(nil)
    signals.onExtract.withLock {
      $0 = { n in
        if n == 25 { swap.withLock { $0 = Task { try await indexer.setEmbedder(b, openVectors: open) } } }
      }
    }
    _ = try await indexer.run()  // the caller is carried over to the run after the swap
    try await swap.withLock { $0 }!.value
    await indexer.waitUntilIdle()

    let store = try #require(storeB.withLock { $0 })
    #expect(try await store.reconcile() == 0, "no flag claims a vector the new index lacks")
    #expect(try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset WHERE embedded = 1") } == 40)
    #expect(await store.count == 40)
    // Signals are kept across the swap; at most the one asset in flight when the run stopped is redone.
    #expect(signals.extractCalls <= 41)
  }

  /// The taste scan (`run(limit: 500)`) while the model loads: attaching it mid-run carries the caller over, and the
  /// caller must still get its limited run back, not wait for the whole library's catch-up.
  @Test func aLimitedCallerCarriedOverASwapReturnsAfterItsLimit() async throws {
    try await Harness.with(count: 40, videoEvery: nil) { h in
      let indexer = try h.indexer(embedder: false)
      try await indexer.sync()
      let swap = Mutex<Task<Void, any Error>?>(nil)
      let open = h.openSameStore
      h.signals.onExtract.withLock {
        $0 = { n in
          if n == 4 { swap.withLock { $0 = Task { try await indexer.setEmbedder(Harness.embedder, openVectors: open) } } }
        }
      }
      let report = try await indexer.run(limit: 10)
      let signalled = try await h.count("signalsDone = 1")
      #expect(signalled >= 10 && signalled <= 11, "the limit holds across the swap (\(signalled) indexed)")
      #expect(report.processed <= 11)
      try await swap.withLock { $0 }!.value
      await indexer.waitUntilIdle()
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 40, "the catch-up still runs afterwards")
    }
  }

  @Test func aFailedDrainKeepsTheOldEmbedderAndNeverOpensTheNewStore() async throws {
    try await Harness.with(count: 20) { h in
      var config = Harness.testConfig
      config.minimumSaveInterval = .seconds(3600)
      let sink = ControlledSink(base: h.store, log: h.log)
      let indexer = try h.indexer(config: config, vectors: sink)
      try await indexer.sync()
      try await indexer.run()  // first save of the session: flushed
      h.library.state.withLock { s in s.assets += (20..<30).map(FakeLibrary.snapshot) }
      try await indexer.sync()
      try await indexer.run()  // small run within the debounce: 10 vectors stay buffered
      #expect(try await h.count("embedded = 1") == 20)

      sink.failSaves.withLock { $0 = 1 }
      let opened = Mutex(false)
      await #expect(throws: CocoaError.self) {
        try await indexer.setEmbedder(Harness.embedder, openVectors: { _, _ in
          opened.withLock { $0 = true }
          return sink
        })
      }
      #expect(opened.withLock { $0 } == false)
      #expect(await indexer.hasEmbedder)
      try await indexer.flush()
      #expect(try await h.count("embedded = 1") == 30)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  // MARK: I4 library mutations are serialised

  @Test func aRemovalAppliedDuringASlowSyncWins() async throws {
    let fake = FakeLibrary(count: 5)
    let gated = GatedLibrary(fake)
    let db = try AppDatabase.inMemory()
    let repo = Repositories(db)
    let indexer = try Indexer(library: gated, signals: FakeSignals(), repo: repo)
    try await indexer.sync()
    gated.open.withLock { $0 = false }
    gated.entered.withLock { $0 = false }
    let syncing = Task { try await indexer.sync() }
    try await Harness.waitUntil { gated.entered.withLock { $0 } }

    let victim = FakeLibrary.id(2)
    fake.state.withLock { $0.assets.removeAll { $0.id == victim } }
    let applying = Task { try await indexer.apply(LibraryChange(removed: [victim])) }
    try await Task.sleep(for: .milliseconds(20))
    gated.open.withLock { $0 = true }
    _ = try await syncing.value
    #expect(try await applying.value.deleted == 1)
    #expect(try await repo.asset(id: victim)?.deleted == true)
  }

  // MARK: I5 / M8 vector purges

  @Test func removedAssetsLoseTheirFlagThenTheirVector() async throws {
    try await Harness.with(count: 20) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      h.log.clear()
      let gone = [FakeLibrary.id(2), FakeLibrary.id(5)]
      h.library.state.withLock { $0.assets.removeAll { gone.contains($0.id) } }
      #expect(try await indexer.sync().deleted == 2)
      #expect(h.log.vectorEvents == ["unflag:2", "remove:2", "save"])
      #expect(await h.store.count == 18)
      #expect(await h.store.vector(for: gone[0]) == nil)
      let row = try #require(try await h.repo.asset(id: gone[0]))
      #expect(row.deleted && !row.embedded && row.deletedAt != nil)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func deletionsWithoutAnEmbedderArePurgedOnceOneIsAttached() async throws {
    try await Harness.with(count: 20) { h in
      let first = try h.indexer()
      try await first.sync()
      try await first.run()
      let later = try h.indexer(embedder: false)
      h.library.state.withLock { $0.assets.removeAll { $0.id == FakeLibrary.id(0) } }
      try await later.sync()
      #expect(try await h.repo.deletedEmbeddedIds() == [FakeLibrary.id(0)], "flag kept until the vector can go")
      try await later.setEmbedder(Harness.embedder, openVectors: h.openSameStore)
      await later.waitUntilIdle()
      #expect(try await h.repo.deletedEmbeddedIds().isEmpty)
      #expect(await h.store.count == 19)
    }
  }

  @Test func contentChangesResetTheAssetAndPurgeItsVector() async throws {
    try await Harness.with(count: 10) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      h.log.clear()
      let edited = FakeLibrary.id(3)
      let report = try await indexer.apply(LibraryChange(changed: [FakeLibrary.id(4)], contentChanged: [edited]))
      #expect(report.updated == 2)
      #expect(h.log.all.contains("reset:1"))
      #expect(h.log.vectorEvents == ["remove:1", "save"])
      #expect(await h.store.vector(for: edited) == nil)
      #expect(try await h.repo.asset(id: FakeLibrary.id(4))?.embedded == true, "metadata change keeps the vector")
      #expect(try await indexer.pendingCount() == 1)
      #expect(try await indexer.run().processed == 1)
      #expect(h.signals.extractCalls == 11)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func withAStoreButNoEmbedderStaleVectorsGoRightAway() async throws {
    try await Harness.with(count: 10) { h in
      let first = try h.indexer()
      try await first.sync()
      try await first.run()
      // The model hasn't loaded yet, but the store is open at the last revision.
      let later = try h.indexer(embedder: false, vectors: h.vectors)
      h.log.clear()

      let edited = FakeLibrary.id(3)
      try await later.apply(LibraryChange(contentChanged: [edited]))
      #expect(await h.store.vector(for: edited) == nil)
      #expect(h.log.vectorEvents == ["remove:1", "save"])

      h.library.state.withLock { $0.assets.removeAll { $0.id == FakeLibrary.id(5) } }
      try await later.sync()
      #expect(await h.store.vector(for: FakeLibrary.id(5)) == nil)
      #expect(try await h.repo.deletedEmbeddedIds().isEmpty)
      #expect(await h.store.count == 8)
      #expect(try await h.store.reconcileReport() == ReconcileReport(clearedFlags: 0, removedVectors: 0))
    }
  }

  @Test func withNoStoreAtAllTheNextOpenRemovesTheStaleVector() async throws {
    try await Harness.with(count: 10) { h in
      let first = try h.indexer()
      try await first.sync()
      try await first.run()
      let later = try h.indexer(embedder: false)
      let edited = FakeLibrary.id(3)
      try await later.apply(LibraryChange(contentChanged: [edited]))
      #expect(await h.store.vector(for: edited) != nil, "nothing to purge through")
      #expect(try await h.store.reconcileReport() == ReconcileReport(clearedFlags: 0, removedVectors: 1))
      #expect(await h.store.vector(for: edited) == nil)
    }
  }

  // MARK: I6 writes

  @Test func flushDuringARunWritesWhatIsDoneAndTheRunCarriesOn() async throws {
    try await Harness.with(count: 450) { h in
      var config = Harness.testConfig
      config.minimumSaveInterval = .seconds(3600)
      let indexer = try h.indexer(config: config)
      try await indexer.sync()
      h.signals.onExtractAsync.withLock { $0 = { n in if n == 100 { try? await indexer.flush() } } }
      try await indexer.run()
      // The mid-run flush saved 99 vectors; the run is small and inside the debounce, so the rest wait.
      #expect(h.log.vectorEvents == ["upsert:99", "save", "embedded:99"])
      #expect(try await h.count("signalsDone = 1") == 450)
      #expect(try await indexer.pendingCount() == 0, "buffered vectors are not pending work")
      #expect(try await indexer.run().processed == 0, "and are not embedded twice")
      try await indexer.flush()
      #expect(h.log.vectorEvents == ["upsert:99", "save", "embedded:99", "upsert:351", "save", "embedded:351"])
      #expect(try await h.count("embedded = 1") == 450)
    }
  }

  @Test func aFailedSaveNeverFlagsAndTheVectorsAreRetried() async throws {
    try await Harness.with(count: 450) { h in
      let sink = ControlledSink(base: h.store, log: h.log)
      sink.failSaves.withLock { $0 = 3 }
      let indexer = try h.indexer(vectors: sink)
      try await indexer.sync()
      await #expect(throws: CocoaError.self) { try await indexer.run() }
      #expect(await indexer.progress.phase == .failed)
      #expect(try await h.count("embedded = 1") == 0)
      #expect(try await h.count("signalsDone = 1") == 450, "signals are committed independently")
      await #expect(throws: CocoaError.self) { try await indexer.flush() }  // third failure surfaces
      try await indexer.flush()
      #expect(try await h.count("embedded = 1") == 450)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func embedderFailuresAndWrongLengthVectorsSkipOnlyThatAsset() async throws {
    try await Harness.with(count: 20, videoEvery: nil) { h in
      let indexer = try Indexer(library: h.library, signals: h.signals, repo: h.recordingRepo,
                                embedder: FlakyEmbedder(throwOn: [3], wrongLengthOn: [5]), vectors: h.vectors,
                                config: Harness.testConfig)
      try await indexer.sync()
      let report = try await indexer.run()
      #expect(report.embedFailures == 2)
      #expect(report.embedded == 18)
      #expect(try await h.count("signalsDone = 1") == 20)
      #expect(try await h.count("embedded = 1") == 18)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func thumbnailsLoadInGroupsOfEightWithOneGroupAhead() async throws {
    try await Harness.with(count: 200, videoEvery: nil) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let violations = Mutex<[String]>([])
      let library = h.library
      h.signals.onExtract.withLock {
        $0 = { n in
          let group = (n - 1) / 8 + 1  // 1-based group of the asset being processed
          let requested = library.state.withLock { $0.thumbnailCallSizes.count }
          if requested < group || requested > min(group + 1, 25) {
            violations.withLock { $0.append("asset \(n): \(requested) groups requested") }
          }
        }
      }
      try await indexer.run()
      #expect(h.library.state.withLock { $0.thumbnailCallSizes } == Array(repeating: 8, count: 25))
      #expect(violations.withLock { $0 } == [])
    }
  }

  @Test func reserveOnlyForLargeBatches() async throws {
    try await Harness.with(count: 4500) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      _ = try await indexer.run(limit: 450)
      #expect(!h.log.all.contains { $0.hasPrefix("reserve:") }, "450 is below the threshold")
      _ = try await indexer.run()
      #expect(h.log.all.filter { $0.hasPrefix("reserve:") } == ["reserve:4500"])
    }
  }

  @Test func smallRunsDebounceTheirVectorSave() async throws {
    try await Harness.with(count: 30) { h in
      var config = Harness.testConfig
      config.minimumSaveInterval = .seconds(3600)
      config.pageSize = 10
      config.vectorFlushEvery = 20
      let indexer = try h.indexer(config: config)
      try await indexer.sync()
      _ = try await indexer.run(limit: 10)  // first save of the session
      #expect(h.log.vectorEvents == ["upsert:10", "save", "embedded:10"])
      _ = try await indexer.run(limit: 10)  // small and recent: buffered
      #expect(h.log.vectorEvents.count == 3)
      _ = try await indexer.run()  // 10 more is still small: buffered too
      #expect(h.log.vectorEvents.count == 3)
      #expect(try await indexer.pendingCount() == 0)
      try await indexer.flush()
      #expect(h.log.vectorEvents.suffix(3) == ["upsert:20", "save", "embedded:20"])

      h.library.state.withLock { s in s.assets += (30..<60).map(FakeLibrary.snapshot) }
      try await indexer.sync()
      h.log.clear()
      _ = try await indexer.run()  // 30 new vectors >= vectorFlushEvery: flushed at 20 and at the end
      #expect(h.log.vectorEvents == ["upsert:20", "save", "embedded:20", "upsert:10", "save", "embedded:10"])
    }
  }

  // MARK: M9 progress

  @Test func aNewSubscriberSeesIdleNotALeftoverFinished() async throws {
    try await Harness.with(count: 10) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      #expect(await indexer.progress.phase == .finished)
      h.library.state.withLock { s in s.assets += (10..<20).map(FakeLibrary.snapshot) }
      try await indexer.sync()
      let updates = await indexer.progressUpdates()
      var iterator = updates.makeAsyncIterator()
      let first = await iterator.next()
      #expect(first?.phase == .idle)
      let previousRun = try #require(first?.runId)
      let run = Task { try await indexer.run() }
      var seen: [IndexProgress.Phase] = []
      while let update = await iterator.next() {
        if update.runId == previousRun { continue }
        seen.append(update.phase)
        if update.phase == .finished { break }
      }
      _ = try await run.value
      #expect(seen.first == .started || seen.first == .indexing)
      #expect(seen.last == .finished)
    }
  }

  @Test func syncDoesNotOverwriteARunningRunsProgress() async throws {
    try await Harness.with(count: 30, hotReads: .max) { h in
      let indexer = try h.indexer(pollInterval: .milliseconds(1))
      try await indexer.sync()
      let run = Task { try await indexer.run() }
      try await Harness.waitUntil { await indexer.progress.phase == .thermalPause }
      try await indexer.sync()
      #expect(await indexer.progress.phase == .thermalPause)
      run.cancel()
      await #expect(throws: CancellationError.self) { try await run.value }
      await indexer.waitUntilIdle()
      #expect(await indexer.progress.phase == .cancelled)
    }
  }
}
