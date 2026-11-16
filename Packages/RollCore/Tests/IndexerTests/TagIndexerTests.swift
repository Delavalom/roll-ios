import CoreGraphics
import Foundation
import Library
import Signals
import Synchronization
import Testing
@testable import Indexer
@testable import Store

/// Fixed labels per call. `failOn` call numbers return nil (Vision failed); `onClassify` runs inside each call.
final class FakeClassifier: TagSource {
  let revision = "fake-classifier-1"
  let failOn: Set<Int>
  private let calls = Mutex(0)
  let onClassify = Mutex<(@Sendable (Int) async -> Void)?>(nil)

  init(failOn: Set<Int> = []) { self.failOn = failOn }

  var callCount: Int { calls.withLock { $0 } }

  func classify(_ image: CGImage) async throws(CancellationError) -> [SceneLabel]? {
    let n = calls.withLock { c in c += 1; return c }
    if let hook = onClassify.withLock({ $0 }) { await hook(n) }
    if Task.isCancelled { throw CancellationError() }
    return failOn.contains(n) ? nil : [SceneLabel(identifier: "dog", confidence: 0.9),
                                       SceneLabel(identifier: "grass", confidence: 0.2)]
  }
}

/// The real `Repositories`, with tag commits logged.
struct RecordingTagRepo: TagRepository {
  let base: Repositories
  let log: EventLog

  func tagCandidateIds(revision: String, retryUnread: Bool, limit: Int) async throws -> [String] {
    try await base.tagCandidateIds(revision: revision, retryUnread: retryUnread, limit: limit)
  }
  func tagCandidateCount(revision: String, retryUnread: Bool) async throws -> Int {
    try await base.tagCandidateCount(revision: revision, retryUnread: retryUnread)
  }
  func commitTags(_ items: [TagFields]) async throws {
    log.append("tags:\(items.count)")
    try await base.commitTags(items)
  }
}

struct TagIndexerTests {
  /// `count` analysed photos, newest first (a00000 newest), plus one not analysed yet.
  private func seed(_ repo: Repositories, _ count: Int) async throws {
    var rows = (0..<count).map { i in
      AssetRecord(id: FakeLibrary.id(i), mediaType: i == 1 ? MediaKind.video : MediaKind.image, subtypes: 0,
                  created: Double(1_000 - i), pixelW: 4000, pixelH: 3000, duration: nil, isFavorite: false,
                  burstId: nil, uti: nil, estBytes: 1, cloudOnly: false, embedded: true, signalsDone: true, blur: nil,
                  aesthetic: nil, isUtility: nil, sensitive: nil, phash: nil, featurePrint: nil, deleted: false)
    }
    var pending = rows[0]
    pending.id = "pending"
    pending.signalsDone = false
    rows.append(pending)
    try await repo.replaceAssetsForTesting(rows)
  }

  private func indexer(_ h: Harness, classifier: FakeClassifier, hotReads: Int = 0,
                       config: TagPassConfig = TagPassConfig()) -> TagIndexer {
    TagIndexer(library: h.library, classifier: classifier, repo: RecordingTagRepo(base: h.repo, log: h.log),
               thermal: ThermalGate(provider: FakeThermal(hotReads: hotReads, hot: .fair), pollInterval: .milliseconds(1),
                                    pausesAt: .fair),
               config: config)
  }

  @Test func theDefaultsAreTheEvalsLabels() {
    #expect(TagPassConfig().side == 360)
    #expect(SceneClassifier().minConfidence == 0.1 && SceneClassifier().maxLabels == 10)
    #expect(TagIndexer.defaultThermal.pausesAt == .fair, "like the text pass, it waits while the phone is warm")
  }

  @Test func labelsAnalysedPhotosNewestFirstAtTheTagSize() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, 3)
      let classifier = FakeClassifier()
      let tags = indexer(h, classifier: classifier)
      #expect(try await tags.pendingCount() == 3)
      #expect(try await tags.run() == TagReport(read: 3, tagged: 3))
      let state = h.library.state.withLock { $0 }
      #expect(state.thumbnailIds == ["a00000", "a00001", "a00002"], "videos by their poster frame")
      #expect(Set(state.requestedSides) == [360] && state.networkRequests.isEmpty)
      #expect(try await h.repo.tags(assetId: "a00000").map(\.label) == ["dog", "grass"])
      #expect(try await h.repo.tagLabels(minConfidence: 0.3).keys.sorted() == ["a00000", "a00001", "a00002"])
      #expect(try await tags.pendingCount() == 0)
      #expect(try await tags.run() == TagReport(), "nothing left: resumable, each photo read once")
      #expect(classifier.callCount == 3)
    }
  }

  @Test func photosWithoutALocalImageAreRecordedUnreadAndRetriedOnlyWithTheNetwork() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, 4)
      h.library.set(.inCloud, for: ["a00000"])
      h.library.set(.previewOnly, for: ["a00001"])  // an 8 px preview: under minimumPreviewSide
      h.library.set(.failedAlways, for: ["a00002"])
      let tags = indexer(h, classifier: FakeClassifier())
      #expect(try await tags.run() == TagReport(read: 1, tagged: 1, unread: 2, failed: 1))
      #expect(try await h.repo.tags(assetId: "a00000").isEmpty)
      #expect(try await tags.run() == TagReport(), "a local pass doesn't retry them")
      #expect(try await tags.pendingCount(allowNetwork: true) == 3)
      let report = try await tags.run(allowNetwork: true)
      #expect(report.read == 1 && report.unread == 1 && report.failed == 1, "the iCloud one downloads")
      var small = TagPassConfig()
      small.minimumPreviewSide = 8
      #expect(try await indexer(h, classifier: FakeClassifier(), config: small).run(allowNetwork: true).read == 1,
              "a big enough local preview is classified")
    }
  }

  @Test func aVisionFailureIsRecordedUnreadAndWarmthOnlyPauses() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, 3)
      let report = try await indexer(h, classifier: FakeClassifier(failOn: [1]), hotReads: 3).run()
      #expect(report == TagReport(read: 2, tagged: 2, unread: 0, failed: 1, thermalPolls: 3))
    }
  }

  @Test func cancellingKeepsWhatWasReadAndResumesWhereItStopped() async throws {
    try await Harness.with(count: 0) { h in
      try await seed(h.repo, 5)
      let classifier = FakeClassifier()
      let entered = Mutex(false)
      classifier.onClassify.withLock { $0 = { n in
        guard n == 3 else { return }
        entered.withLock { $0 = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
      } }
      var config = TagPassConfig()
      config.commitEvery = 100
      let tags = indexer(h, classifier: classifier, config: config)
      let run = Task { try await tags.run() }
      try await Harness.waitUntil { entered.withLock { $0 } }
      run.cancel()
      await #expect(throws: CancellationError.self) { try await run.value }
      #expect(h.log.all == ["tags:2"])
      #expect(try await tags.pendingCount() == 3)
      classifier.onClassify.withLock { $0 = nil }
      #expect(try await tags.run().read == 3)
    }
  }
}
