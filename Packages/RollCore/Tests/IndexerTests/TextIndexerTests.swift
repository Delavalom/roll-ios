import CoreGraphics
import Foundation
import Library
import Signals
import Synchronization
import Testing
@testable import Indexer
@testable import Store

/// Fixed text per call. `failOn` call numbers return nil (Vision failed); `onRecognize` runs inside each call.
final class FakeReader: TextSource {
  let revision = "fake-reader-1"
  let failOn: Set<Int>
  private let calls = Mutex(0)
  let onRecognize = Mutex<(@Sendable (Int) async -> Void)?>(nil)

  init(failOn: Set<Int> = []) { self.failOn = failOn }

  var callCount: Int { calls.withLock { $0 } }

  func recognize(_ image: CGImage) async throws(CancellationError) -> String? {
    let n = calls.withLock { c in c += 1; return c }
    if let hook = onRecognize.withLock({ $0 }) { await hook(n) }
    if Task.isCancelled { throw CancellationError() }
    return failOn.contains(n) ? nil : "Uber receipt #\(n)"
  }
}

/// The real `Repositories`, with text commits logged.
struct RecordingTextRepo: TextRepository {
  let base: Repositories
  let log: EventLog

  func textCandidateIds(revision: String, retryUnread: Bool, limit: Int) async throws -> [String] {
    try await base.textCandidateIds(revision: revision, retryUnread: retryUnread, limit: limit)
  }
  func textCandidateCount(revision: String, retryUnread: Bool) async throws -> Int {
    try await base.textCandidateCount(revision: revision, retryUnread: retryUnread)
  }
  func commitText(_ items: [TextFields]) async throws {
    log.append("text:\(items.count)")
    try await base.commitText(items)
  }
}

struct TextIndexerTests {
  /// Rows: id → (screenshot subtype, isUtility, signalsDone, mediaType); `created` falls with the index (first = newest).
  private func seed(_ repo: Repositories,
                    _ rows: [(id: String, shot: Bool, utility: Bool?, done: Bool, media: Int)]) async throws {
    try await repo.replaceAssetsForTesting(rows.enumerated().map { i, r in
      AssetRecord(id: r.id, mediaType: r.media, subtypes: r.shot ? MediaSubtype.screenshot : 0,
                  created: Double(1_000 - i), pixelW: 1170, pixelH: 2532, duration: nil, isFavorite: false, burstId: nil,
                  uti: nil, estBytes: 1, cloudOnly: false, embedded: false, signalsDone: r.done, blur: nil,
                  aesthetic: nil, isUtility: r.utility, sensitive: nil, phash: nil, featurePrint: nil, deleted: false)
    })
  }

  private func shots(_ n: Int) -> [(id: String, shot: Bool, utility: Bool?, done: Bool, media: Int)] {
    (0..<n).map { (id: FakeLibrary.id($0), shot: true, utility: false, done: true, media: MediaKind.image) }
  }

  private func indexer(_ h: Harness, reader: FakeReader, hotReads: Int = 0, hot: ProcessInfo.ThermalState = .fair,
                       config: TextPassConfig = TextPassConfig()) -> TextIndexer {
    TextIndexer(library: h.library, reader: reader, repo: RecordingTextRepo(base: h.repo, log: h.log),
                thermal: ThermalGate(provider: FakeThermal(hotReads: hotReads, hot: hot), pollInterval: .milliseconds(1),
                                     pausesAt: .fair),
                config: config)
  }

  @Test func theGateConstantsAreLibrarysOwn() {
    #expect(TextGate.screenshotSubtype == MediaSubtype.screenshot)
    #expect(TextGate.imageMediaType == MediaKind.image)
  }

  @Test func readsGatedImagesNewestFirstAtTheTextSizeAndMakesTheirWordsSearchable() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, [
        ("a00000", true, false, true, MediaKind.image),   // screenshot
        ("a00001", false, nil, true, MediaKind.image),    // plain photo
        ("a00002", false, true, true, MediaKind.image),   // utility
        ("a00003", true, true, true, MediaKind.video),    // video: never
        ("a00004", true, nil, false, MediaKind.image),    // signals not done yet
      ])
      let reader = FakeReader()
      let text = indexer(h, reader: reader)
      #expect(try await text.pendingCount() == 2)
      let report = try await text.run()
      #expect(report == TextReport(read: 2, withWords: 2, unread: 0, failed: 0, thermalPolls: 0))
      #expect(reader.callCount == 2)
      let state = h.library.state.withLock { $0 }
      #expect(state.thumbnailIds == ["a00000", "a00002"])
      #expect(Set(state.requestedSides) == [TextPassConfig().side])
      #expect(state.networkRequests.isEmpty)
      #expect(try await h.repo.keywordCoverage(terms: ["uber", "receipt"]) == ["a00000": 1, "a00002": 1])
      #expect(try await h.repo.text(assetId: "a00000")?.revision == text.revision)
      #expect(try await text.pendingCount() == 0)
      #expect(try await text.run() == TextReport(), "nothing left")
      #expect(reader.callCount == 2)
    }
  }

  @Test func theDefaultsComeFromTheMacMeasurement() {
    #expect(TextPassConfig().side == 960)
    #expect(TextIndexer.defaultThermal.pausesAt == .fair, "a backfill is low priority: it waits while the phone is warm")
  }

  @Test func anotherTextSizeIsAnotherRevisionSoEverythingIsReadAgain() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(3))
      let reader = FakeReader()
      _ = try await indexer(h, reader: reader).run()
      var larger = TextPassConfig()
      larger.side = 1600
      let again = indexer(h, reader: reader, config: larger)
      #expect(again.revision != indexer(h, reader: reader).revision)
      #expect(try await again.run().read == 3)
      #expect(reader.callCount == 6)
    }
  }

  @Test func limitTakesTheNewestFirst() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(5))
      let text = indexer(h, reader: FakeReader())
      #expect(try await text.run(limit: 2).read == 2)
      #expect(h.library.state.withLock { $0.thumbnailIds } == ["a00000", "a00001"])
      #expect(try await text.pendingCount() == 3)
    }
  }

  @Test func imagesThatCantBeLoadedAreRecordedUnreadAndRetriedOnlyWithTheNetwork() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(4))
      h.library.set(.inCloud, for: ["a00000"])
      h.library.set(.previewOnly, for: ["a00001"])  // an 8 px preview: too small to read
      h.library.set(.failedAlways, for: ["a00002"])
      let reader = FakeReader()
      let text = indexer(h, reader: reader)
      #expect(try await text.run() == TextReport(read: 1, withWords: 1, unread: 2, failed: 1, thermalPolls: 0))
      let unread = try #require(try await h.repo.text(assetId: "a00000"))
      #expect(unread.side == nil && unread.text.isEmpty)
      #expect(try await h.repo.text(assetId: "a00003")?.side == 8, "the side of the image read")
      #expect(try await text.run() == TextReport(), "a local pass doesn't retry them")
      #expect(try await text.pendingCount(allowNetwork: true) == 3)
      let report = try await text.run(allowNetwork: true)
      #expect(report.read == 1 && report.unread == 1 && report.failed == 1, "the iCloud one downloads")
      #expect(h.library.state.withLock { $0.networkRequests }.contains("a00000"))
      #expect(try await h.repo.keywordCoverage(terms: ["uber"]).keys.sorted() == ["a00000", "a00003"])
    }
  }

  @Test func aVisionFailureIsRecordedUnread() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(2))
      let text = indexer(h, reader: FakeReader(failOn: [1]))
      #expect(try await text.run() == TextReport(read: 1, withWords: 1, unread: 0, failed: 1, thermalPolls: 0))
      #expect(try await h.repo.text(assetId: "a00000")?.side == nil)
    }
  }

  @Test func warmthPausesThePassWithoutFailingIt() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(3))
      let report = try await indexer(h, reader: FakeReader(), hotReads: 4, hot: .fair).run()
      #expect(report.read == 3 && report.thermalPolls == 4)
    }
  }

  @Test func wordsAreCommittedEveryFewImagesAndAtTheEnd() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(5))
      var config = TextPassConfig()
      config.commitEvery = 2
      _ = try await indexer(h, reader: FakeReader(), config: config).run()
      #expect(h.log.all == ["text:2", "text:2", "text:1"])
    }
  }

  @Test func cancellingKeepsTheImagesAlreadyReadAndDropsTheOneInFlight() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(5))
      let reader = FakeReader()
      let entered = Mutex(false)
      reader.onRecognize.withLock { $0 = { n in
        guard n == 3 else { return }
        entered.withLock { $0 = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
      } }
      var config = TextPassConfig()
      config.commitEvery = 100
      let text = indexer(h, reader: reader, config: config)
      let run = Task { try await text.run() }
      try await Harness.waitUntil { entered.withLock { $0 } }
      run.cancel()
      await #expect(throws: CancellationError.self) { try await run.value }
      #expect(h.log.all == ["text:2"])
      #expect(try await text.pendingCount() == 3)
      reader.onRecognize.withLock { $0 = nil }
      #expect(try await text.run().read == 3)
    }
  }

  @Test func cancelStopsTheActiveRun() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(3))
      let reader = FakeReader()
      let entered = Mutex(false)
      reader.onRecognize.withLock { $0 = { _ in
        entered.withLock { $0 = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
      } }
      let text = indexer(h, reader: reader)
      let run = Task { try await text.run() }
      try await Harness.waitUntil { entered.withLock { $0 } }
      await text.cancel()
      await #expect(throws: CancellationError.self) { try await run.value }
    }
  }

  @Test func concurrentRunsGoOneAfterAnother() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, shots(6))
      let reader = FakeReader()
      let text = indexer(h, reader: reader)
      async let first = text.run()
      async let second = text.run()
      let reports = try await [first, second]
      #expect(reports.map(\.read).reduce(0, +) == 6)
      #expect(reader.callCount == 6, "no image is read twice")
    }
  }
}
