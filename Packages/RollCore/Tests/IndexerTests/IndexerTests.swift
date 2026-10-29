import Embedding
import Foundation
import GRDB
import Library
import Store
import Synchronization
import Testing
@testable import Indexer

struct IndexerTests {
  // MARK: cadence and commit order

  @Test func indexesEveryAssetWithThreeSignalCommitsAndOneVectorFlush() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let report = try await indexer.run()

      #expect(report.processed == 450)
      #expect(report.embedded == 450)
      #expect(h.log.signalCommits == ["signals:200", "signals:200", "signals:50"])
      #expect(h.log.vectorEvents == ["upsert:450", "save", "embedded:450"])
      #expect(h.signals.extractCalls == 450)
      #expect(h.signals.refreshCalls == 3, "refreshPolicy once per 200-asset batch")
      #expect(try await h.repo.pendingAssets(limit: 1000).isEmpty)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1 AND blur = 1.5 AND phash = 42") == 450)
      #expect(await h.store.count == 450)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func videosUseAFrameAndPhotosUseThumbnails() async throws {
    try await Harness.with(count: 100) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      let state = h.library.state.withLock { $0 }
      #expect(state.videoFrameIds.count == 10)
      #expect(state.thumbnailIds.count == 90)
      #expect(Set(state.videoFrameIds).isDisjoint(with: state.thumbnailIds))
      #expect(state.networkRequests.isEmpty)
    }
  }

  @Test func fortyFiveHundredAssetsFlushVectorsAtTwoThousandFourThousandAndTheEnd() async throws {
    try await Harness.with(count: 4500) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()

      #expect(h.log.vectorEvents == [
        "upsert:2000", "save", "embedded:2000",
        "upsert:2000", "save", "embedded:2000",
        "upsert:500", "save", "embedded:500",
      ])
      #expect(h.log.signalCommits.count == 23)
      // The first flush follows the 10th signal commit (2,000 assets).
      let all = h.log.all
      let firstUpsert = try #require(all.firstIndex(of: "upsert:2000"))
      #expect(all[..<firstUpsert].filter { $0.hasPrefix("signals:") }.count == 10)
      #expect(try await h.count("embedded = 1") == 4500)
      #expect(await h.store.count == 4500)
    }
  }

  @Test func flushWithNothingBufferedWritesNothing() async throws {
    try await Harness.with(count: 0) { h in
      let indexer = try h.indexer()
      try await indexer.flush()
      #expect(try await indexer.run().processed == 0)
      #expect(h.log.all.isEmpty)
    }
  }

  // MARK: thermal

  @Test func seriousThermalStateDelaysButDoesNotFail() async throws {
    try await Harness.with(count: 50, hotReads: 2) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let report = try await indexer.run()
      // Read 1 (hot) pauses, read 2 (hot) sleeps one poll, read 3 resumes; then one read per asset.
      #expect(report.thermalPolls == 1)
      #expect(h.thermal.reads == 52)
      #expect(report.processed == 50)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 50)
    }
  }

  // MARK: cancellation

  @Test func cancellingMidRunKeepsCompletedWorkAndLeavesTheRestPending() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let handle = Mutex<Task<IndexReport, any Error>?>(nil)
      h.signals.onExtract.withLock { $0 = { n in if n == 250 { handle.withLock { $0 }?.cancel() } } }
      let task = Task { try await indexer.run() }
      handle.withLock { $0 = task }
      await #expect(throws: CancellationError.self) { try await task.value }
      await indexer.waitUntilIdle()

      // Asset 250 was mid-flight when cancelled: discarded. The 249 before it are committed and flushed.
      #expect(try await h.count("signalsDone = 1") == 249)
      #expect(try await h.count("embedded = 1") == 249)
      #expect(await h.store.count == 249)
      #expect(try await h.repo.pendingAssets(limit: 1000).count == 201)
      #expect(try await h.count("cloudOnly = 1") == 0)
      #expect(try await h.store.reconcile() == 0, "no flag without a vector")
      #expect(h.log.signalCommits == ["signals:200", "signals:49"])
      #expect(h.log.vectorEvents == ["upsert:249", "save", "embedded:249"])

      // The next run picks up exactly the rest.
      h.signals.onExtract.withLock { $0 = nil }
      #expect(try await indexer.run().processed == 201)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 450)
    }
  }

  @Test func cancelStopsTheActiveRun() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      h.signals.onExtract.withLock { $0 = { n in if n == 10 { Task { await indexer.cancel() } } } }
      await #expect(throws: CancellationError.self) { try await indexer.run() }
      await indexer.waitUntilIdle()
      let done = try await h.count("embedded = 1")
      #expect(done > 0 && done < 450)
      #expect(try await h.store.reconcile() == 0)
    }
  }

  // MARK: thumbnail outcomes

  @Test func inCloudMarksCloudOnlyAndANetworkRunPicksItUp() async throws {
    try await Harness.with(count: 30) { h in
      let cloud = [FakeLibrary.id(3), FakeLibrary.id(7)]
      h.library.set(.inCloud, for: cloud)
      let indexer = try h.indexer()
      try await indexer.sync()
      let first = try await indexer.run()
      #expect(first.cloudOnly == 2)
      #expect(try await h.count("cloudOnly = 1 AND signalsDone = 0 AND embedded = 0") == 2)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 28)
      #expect(try await indexer.pendingCount() == 0, "cloud-only assets wait for a network run")

      // A local run skips them entirely.
      let requestsBefore = h.library.state.withLock { $0.thumbnailIds.count }
      #expect(try await indexer.run().processed == 0)
      #expect(h.library.state.withLock { $0.thumbnailIds.count } == requestsBefore)

      // A network run downloads their thumbnails. The originals are still in iCloud, so the flag stays.
      let networked = try await indexer.run(allowNetwork: true)
      #expect(networked.processed == 2)
      #expect(Set(h.library.state.withLock { $0.networkRequests }) == Set(cloud))
      #expect(try await h.count("cloudOnly = 1 AND signalsDone = 1 AND embedded = 1 AND source = 'full'") == 2)
      #expect(try await h.count("cloudOnly = 0 AND signalsDone = 1 AND embedded = 1 AND source = 'full'") == 28)
    }
  }

  @Test func inCloudDuringEmbedOnlyCatchUpKeepsTheSignals() async throws {
    try await Harness.with(count: 20) { h in
      let indexer = try h.indexer(embedder: false)
      try await indexer.sync()
      try await indexer.run()
      h.library.set(.inCloud, for: [FakeLibrary.id(4)])
      try await indexer.setEmbedder(Harness.embedder, openVectors: h.openSameStore)
      try await indexer.run()
      let row = try #require(try await h.repo.asset(id: FakeLibrary.id(4)))
      #expect(row.cloudOnly && row.signalsDone && !row.embedded)
      #expect(row.blur == 1.5 && row.phash == 42 && row.featurePrint == Data([1, 2, 3]))
    }
  }

  @Test func failedThumbnailIsSkippedWithoutAMarkAndRetriedNextRun() async throws {
    try await Harness.with(count: 20) { h in
      let flaky = FakeLibrary.id(5)
      h.library.set(.failedOnce, for: [flaky])
      let indexer = try h.indexer()
      try await indexer.sync()
      let first = try await indexer.run()
      #expect(first.failed == 1)
      let row = try #require(try await h.repo.asset(id: flaky))
      #expect(!row.signalsDone && !row.embedded && !row.cloudOnly)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 19)

      #expect(try await indexer.run().processed == 1)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 20)
    }
  }

  @Test func cancelledThumbnailWithoutTaskCancellationCountsAsAFailedLoad() async throws {
    try await Harness.with(count: 40) { h in
      h.library.set(.cancelled, for: [FakeLibrary.id(10)])
      let indexer = try h.indexer()
      try await indexer.sync()
      let report = try await indexer.run()
      #expect(report.failed == 1)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 39)
      let row = try #require(try await h.repo.asset(id: FakeLibrary.id(10)))
      #expect(!row.signalsDone && !row.cloudOnly && !row.embedded && row.attempts == 1)
    }
  }

  @Test func threeFailedLoadsLeavePendingAndResetFailuresBringsThemBack() async throws {
    try await Harness.with(count: 10) { h in
      h.library.set(.failedAlways, for: [FakeLibrary.id(3)])
      let indexer = try h.indexer()
      try await indexer.sync()
      for expected in [1, 1, 1, 0] {
        #expect(try await indexer.run().failed == expected)
      }
      #expect(try await indexer.pendingCount() == 0)
      #expect(try await h.repo.failedAssetCount() == 1)
      #expect(try await h.repo.resetFailures() == 1)
      #expect(try await indexer.pendingCount() == 1)
    }
  }

  // MARK: optional embedder

  @Test func withoutAnEmbedderOnlySignalsRunAndCatchUpEmbedsLater() async throws {
    try await Harness.with(count: 450) { h in
      let indexer = try h.indexer(embedder: false)
      try await indexer.sync()
      let report = try await indexer.run()
      #expect(report.embedded == 0)
      #expect(try await h.count("signalsDone = 1") == 450)
      #expect(try await h.count("embedded = 1") == 0)
      #expect(h.log.vectorEvents.isEmpty)
      #expect(await h.store.count == 0)
      #expect(try await indexer.pendingCount() == 0, "nothing to do until an embedder arrives")
      #expect(try await indexer.run().processed == 0)

      try await indexer.setEmbedder(Harness.embedder, openVectors: h.openSameStore)
      try await indexer.run()
      #expect(h.signals.extractCalls == 450, "catch-up never recomputes signals")
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 450)
      #expect(h.log.vectorEvents == ["upsert:450", "save", "embedded:450"])
      #expect(try await h.store.reconcile() == 0)
    }
  }

  @Test func setEmbedderStartsTheCatchUpByItself() async throws {
    try await Harness.with(count: 60) { h in
      let indexer = try h.indexer(embedder: false)
      try await indexer.sync()
      try await indexer.run()
      try await indexer.setEmbedder(Harness.embedder, openVectors: h.openSameStore)
      var embedded = 0
      for _ in 0..<500 {
        embedded = try await h.count("embedded = 1")
        if embedded == 60 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(embedded == 60)
      #expect(h.signals.extractCalls == 60)
    }
  }

  @Test func setEmbedderRejectsAVectorStoreForAnotherRevision() async throws {
    try await Harness.with(count: 0) { h in
      let indexer = try h.indexer(embedder: false)
      let other = StubEmbedder(dimensions: 8, seed: 99)
      await #expect(throws: IndexerError.embedderMismatch(embedder: other.revision, vectors: Harness.embedder.revision)) {
        try await indexer.setEmbedder(other, openVectors: h.openSameStore)
      }
      #expect(await indexer.hasEmbedder == false, "a store for another revision leaves search unavailable")
      #expect(throws: IndexerError.self) {
        _ = try Indexer(library: h.library, signals: h.signals, repo: h.recordingRepo, embedder: Harness.embedder, vectors: nil)
      }
    }
  }

  // MARK: sync

  @Test func syncNeverLooksUpTypesKeepsStoredOnesAndMarksRemovedAssetsDeleted() async throws {
    let a = AssetSnapshot(id: "a", mediaType: MediaKind.image, created: 3, pixelW: 4000, pixelH: 3000)
    let b = AssetSnapshot(id: "b", mediaType: MediaKind.image, created: 2, pixelW: 4000, pixelH: 3000)
    let v = AssetSnapshot(id: "v", mediaType: MediaKind.video, subtypes: MediaSubtype.videoHighFrameRate, created: 1,
                          pixelW: 1920, pixelH: 1080, duration: 4)
    let library = FakeLibrary(assets: [a, b, v])
    library.state.withLock { $0.utiTable = ["a": "public.png", "b": "public.png", "v": "com.apple.quicktime-movie"] }
    try await Harness.with(library: library) { h in
      let indexer = try h.indexer()
      let first = try await indexer.sync()
      #expect(first == SyncReport(inserted: 3, updated: 0, deleted: 0))
      #expect(library.state.withLock { $0.utiCalls }.isEmpty, "the launch read never asks for file types")
      #expect(try await h.repo.asset(id: "a")?.estBytes == 12_000_000 * 35 / 100, "no UTI yet: HEIC default")
      #expect(try await h.repo.asset(id: "v")?.estBytes == 4 * 18_000_000 / 8)

      #expect(try await indexer.resolveTypes(limit: 10) == 2)
      #expect(try await h.repo.asset(id: "a")?.uti == "public.png")
      #expect(try await h.repo.asset(id: "a")?.estBytes == 12_000_000 * 160 / 100)
      try await h.repo.commitSignals([SignalFields(id: "a", signalsDone: true, blur: 2)])

      // b disappears, d arrives; a's stored type and signals survive the next sync.
      let d = AssetSnapshot(id: "d", mediaType: MediaKind.image, created: 4, pixelW: 100, pixelH: 100)
      library.state.withLock { $0.assets = [d, a, v] }
      #expect(try await indexer.sync() == SyncReport(inserted: 1, updated: 2, deleted: 1))
      let storedA = try #require(try await h.repo.asset(id: "a"))
      #expect(storedA.uti == "public.png" && storedA.estBytes == 12_000_000 * 160 / 100, "estimate uses the stored UTI")
      #expect(storedA.signalsDone && storedA.blur == 2)
      #expect(try await h.repo.asset(id: "b")?.deleted == true)
      #expect(library.state.withLock { $0.utiCalls.count } == 1, "syncs never look types up")
    }
  }

  @Test func requiresResyncRunsAFullSync() async throws {
    try await Harness.with(count: 5) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      h.library.state.withLock { s in
        s.assets.removeFirst()
        s.assets.append(FakeLibrary.snapshot(5))
      }
      let report = try await indexer.apply(LibraryChange(requiresResync: true))
      #expect(report == SyncReport(inserted: 1, updated: 4, deleted: 1))
      #expect(h.library.state.withLock { $0.fetchAllCalls } == 2)
      #expect(try await h.repo.asset(id: FakeLibrary.id(0))?.deleted == true)
      #expect(try await h.repo.asset(id: FakeLibrary.id(5)) != nil)
    }
  }

  @Test func incrementalChangesTouchOnlyTheReportedIds() async throws {
    try await Harness.with(count: 4) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      h.library.state.withLock { s in
        s.assets.removeAll { $0.id == FakeLibrary.id(2) }
        s.assets[0].isFavorite = true
        s.assets.append(FakeLibrary.snapshot(7))
      }
      let change = LibraryChange(inserted: [FakeLibrary.id(7)], removed: [FakeLibrary.id(2)], changed: [FakeLibrary.id(0)])
      let report = try await indexer.apply(change)
      #expect(report == SyncReport(inserted: 1, updated: 1, deleted: 1))
      let state = h.library.state.withLock { $0 }
      #expect(state.fetchAllCalls == 1)
      #expect(state.snapshotCalls == [[FakeLibrary.id(7), FakeLibrary.id(0)]])
      #expect(state.utiCalls.isEmpty, "file types are looked up lazily, never on a library change")
      #expect(try await h.repo.asset(id: FakeLibrary.id(0))?.isFavorite == true)
      #expect(try await h.repo.asset(id: FakeLibrary.id(2))?.deleted == true)
      #expect(try await h.repo.asset(id: FakeLibrary.id(7))?.deleted == false)
    }
  }

  // MARK: progress

  @Test func progressStreamReachesFinishedWithEveryAssetCounted() async throws {
    try await Harness.with(count: 50) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let updates = await indexer.progressUpdates()
      try await indexer.run()
      var last: IndexProgress?
      for await progress in updates where progress.phase == .finished {
        last = progress
        break
      }
      #expect(last?.processed == 50 && last?.total == 50)
      #expect(await indexer.progress == last)
    }
  }
}
