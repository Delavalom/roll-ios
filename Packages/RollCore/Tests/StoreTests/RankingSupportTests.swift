import Foundation
import GRDB
import Testing
@testable import Store

/// Store API used by `Ranking.SwipefileEngine`.
struct RankingSupportTests {
  @Test func dotAllScoresEveryVectorAgainstEveryQuery() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: 8, revision: "r1",
                                        database: try AppDatabase.inMemory())
      #expect(try await store.dotAll([Fixtures.unit(0)]).ids.isEmpty)
      try await store.upsert((0..<8).map { (id: "a\($0)", vector: Fixtures.unit($0)) })
      try await store.remove(id: "a5")
      let queries = [Fixtures.unit(3), Fixtures.unit(1).enumerated().map { $0.offset == 6 ? 0.5 : $0.element }]
      let dots = try await store.dotAll(queries)
      #expect(dots.queryCount == 2)
      #expect(Set(dots.ids) == Set((0..<8).filter { $0 != 5 }.map { "a\($0)" }))
      #expect(dots.scores.count == dots.ids.count * 2)
      for (row, id) in dots.ids.enumerated() {
        let axis = Int(id.dropFirst())!
        #expect(dots[row, 0] == (axis == 3 ? 1 : 0))
        #expect(dots[row, 1] == (axis == 1 ? 1 : axis == 6 ? 0.5 : 0))
      }
      #expect(try await store.dotAll([]).ids.isEmpty)
      await #expect(throws: VectorStoreError.unusableQuery(1)) { _ = try await store.dotAll([Fixtures.unit(0), [1, 2]]) }
      await #expect(throws: VectorStoreError.unusableQuery(0)) {
        _ = try await store.dotAll([[Float.nan] + [Float](repeating: 0, count: 7)])
      }
    }
  }

  /// Query-major (one contiguous run of scores per query, aligned with `ids`), like `VectorIndex.dotAll`: no
  /// transpose, and a scorer can walk one query's scores with stride 1.
  @Test func dotAllIsQueryMajor() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: 8, revision: "r1",
                                        database: try AppDatabase.inMemory())
      try await store.upsert((0..<6).map { (id: "a\($0)", vector: Fixtures.unit($0)) })
      try await store.remove(id: "a2")
      let dots = try await store.dotAll([Fixtures.unit(4), Fixtures.unit(0)])
      let n = dots.ids.count
      #expect(n == 5)
      for (row, id) in dots.ids.enumerated() {
        #expect(dots.scores[row] == (id == "a4" ? 1 : 0))
        #expect(dots.scores[n + row] == (id == "a0" ? 1 : 0))
        #expect(Array(dots.scores(forQuery: 1))[row] == dots[row, 1])
      }
    }
  }

  /// `layout` names the order of `ids`: unchanged while no vector is added or removed, so a ranking pool aligned with
  /// one call's rows (integers, no String lookups) stays aligned with the next call's.
  @Test func dotAllNamesItsLayout() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: 8, revision: "r1",
                                        database: try AppDatabase.inMemory())
      try await store.upsert((0..<4).map { (id: "a\($0)", vector: Fixtures.unit($0)) })
      let first = try await store.dotAll([Fixtures.unit(0)])
      let again = try await store.dotAll([Fixtures.unit(1), Fixtures.unit(2)])
      #expect(again.layout == first.layout && again.ids == first.ids)
      try await store.save()
      #expect(try await store.dotAll([Fixtures.unit(0)]).layout == first.layout)

      try await store.remove(id: "a1")
      let removed = try await store.dotAll([Fixtures.unit(0)])
      #expect(removed.layout != first.layout)
      try await store.upsert(id: "b", vector: Fixtures.unit(5))  // may reuse a1's slot
      let added = try await store.dotAll([Fixtures.unit(0)])
      #expect(added.layout != removed.layout && added.layout != first.layout)
      #expect(Set(added.ids) == ["a0", "a2", "a3", "b"])
    }
  }

  @Test func rankingCandidatesReadOnlyRankingColumnsOfLiveUndecidedAssets() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    try await repo.save(Fixtures.swipefile("sf2"))
    var signals = Fixtures.asset("s", embedded: true)
    signals.blur = 3; signals.aesthetic = -0.5; signals.isUtility = true; signals.sensitive = false
    signals.subtypes = 4; signals.estBytes = 77; signals.previewSide = 300
    try await repo.replaceAssetsForTesting([
      signals,
      Fixtures.asset("plain", embedded: false),
      { var d = Fixtures.asset("gone", embedded: true); d.deleted = true; return d }(),
      Fixtures.asset("decided", embedded: true),
      Fixtures.asset("otherPile", embedded: true),
    ])
    try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: "decided", verdict: .keep, decidedAt: 1))
    try await repo.record(DecisionRecord(swipefileId: "sf2", assetId: "otherPile", verdict: .keep, decidedAt: 2))

    let embedded = try await repo.rankingCandidates(swipefileId: "sf1", embeddedOnly: true, filter: .none)
    #expect(Set(embedded.map(\.id)) == ["s", "otherPile"])
    #expect(embedded.first { $0.id == "s" } == RankingAsset(signals))
    #expect(RankingAsset(signals) == RankingAsset(id: "s", mediaType: 1, subtypes: 4, estBytes: 77, blur: 3,
                                                   aesthetic: -0.5, isUtility: true, sensitive: false))
    let all = try await repo.rankingCandidates(swipefileId: "sf1", embeddedOnly: false, filter: .none)
    #expect(Set(all.map(\.id)) == ["s", "plain", "otherPile"])
    let screenshots = try await repo.rankingCandidates(swipefileId: "sf1", embeddedOnly: false,
                                                       filter: CandidateFilter(subtypesAny: 4))
    #expect(screenshots.map(\.id) == ["s"])
  }

  /// Each filter field, alone and combined, in SQL and in Swift.
  @Test func candidateFilterSQLMatchesSwift() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    var g = SystemRandomNumberGenerator()
    var records: [AssetRecord] = []
    for i in 0..<300 {
      var r = Fixtures.asset("a\(i)", embedded: true, estBytes: [0, 50, 51, 100].randomElement(using: &g)!,
                             mediaType: Int.random(in: 1...3, using: &g))
      r.subtypes = Int.random(in: 0...15, using: &g)
      r.blur = Bool.random(using: &g) ? nil : [0, 24.9, 25, 26].randomElement(using: &g)!
      r.aesthetic = Bool.random(using: &g) ? nil : [-1, -0.3, 0].randomElement(using: &g)!
      r.source = [nil, AnalysisSource.full, .preview].randomElement(using: &g)!
      if r.source == .preview { r.previewSide = [nil, 100, 255, 256, 900].randomElement(using: &g)! }
      records.append(r)
    }
    try await repo.replaceAssetsForTesting(records)
    let filters: [CandidateFilter] = [
      .none, CandidateFilter(mediaType: 2), CandidateFilter(subtypesAny: 4), CandidateFilter(subtypesAny: 6),
      CandidateFilter(bytesAbove: 50), CandidateFilter(blurBelow: 25), CandidateFilter(aestheticBelow: -0.3),
      CandidateFilter(blurBelow: 25, aestheticBelow: -0.3), CandidateFilter(mediaType: 2, bytesAbove: 50),
      CandidateFilter(mediaType: 1, subtypesAny: 4, bytesAbove: 0, blurBelow: 25, aestheticBelow: -0.3),
      CandidateFilter(mediaType: 1, blurBelow: 25),  // Blurry: photos only
    ]
    for filter in filters {
      let sql = Set(try await repo.rankingCandidates(swipefileId: "sf1", embeddedOnly: true, filter: filter).map(\.id))
      let swift = Set(records.filter { filter.matches(RankingAsset($0)) }.map(\.id))
      #expect(sql == swift, "\(filter)")
    }
  }

  /// Blur and aesthetics from a preview smaller than the blur analysis size say nothing about the photo: quality
  /// filters (Blurry) skip those rows until they are upgraded or the preview is big enough.
  @Test func qualityFiltersSkipPreviewsTooSmallToJudge() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    func blurry(_ id: String, _ source: AnalysisSource?, _ side: Int?) -> AssetRecord {
      var r = Fixtures.asset(id, embedded: true)
      r.blur = 3; r.source = source; r.previewSide = side
      return r
    }
    let side = AssetRecord.qualityAnalysisSide
    let records = [blurry("full", .full, 300), blurry("tiny", .preview, side - 1), blurry("big", .preview, side),
                   blurry("unknownSize", .preview, nil), blurry("unknownFull", .full, nil)]
    try await repo.replaceAssetsForTesting(records)
    let filter = CandidateFilter(blurBelow: 25)
    let sql = Set(try await repo.rankingCandidates(swipefileId: "sf1", embeddedOnly: true, filter: filter).map(\.id))
    #expect(sql == ["full", "big"], "unknown sizes aren't judged")
    #expect(Set(records.filter { filter.matches(RankingAsset($0)) }.map(\.id)) == sql)
    let all = try await repo.rankingCandidates(swipefileId: "sf1", embeddedOnly: true, filter: .none)
    #expect(all.count == 5, "only quality filters care")
  }

  @Test func recordSwipeStoresTheDecisionAndCountsIt() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    let first = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .keep, decidedAt: 1))
    #expect(first?.swipesSinceTrain == 1)
    let second = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .action, decidedAt: 2))
    #expect(second?.swipesSinceTrain == 2)
    #expect(try await repo.decisions(for: "sf1").map(\.verdict) == [.action])  // replaced
    #expect(try await repo.recordSwipe(DecisionRecord(swipefileId: "nope", assetId: "a", verdict: .keep, decidedAt: 1)) == nil)
    #expect(try await repo.decisions(for: "nope").isEmpty)
  }

  @Test func undoSwipeRemovesTheDecisionAndUncountsIt() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .keep, decidedAt: 1))
    #expect(try await repo.undoSwipe(swipefileId: "sf1", assetId: "a", retrainEvery: 5) == true)
    #expect(try await repo.decisions(for: "sf1").isEmpty)
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == 0)
    #expect(try await repo.undoSwipe(swipefileId: "sf1", assetId: "a", retrainEvery: 5) == false)
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == 0)  // never negative
  }

  @Test func appliedDecisionsCantBeUndone() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .action, decidedAt: 1))
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "b", verdict: .action, decidedAt: 2))
    try await repo.recordApplied([DecisionKey(swipefileId: "sf1", assetId: "a")], deletedAssetIds: ["a"])
    let counter = try await repo.swipefile(id: "sf1")?.swipesSinceTrain
    #expect(try await repo.undoSwipe(swipefileId: "sf1", assetId: "a", retrainEvery: 5) == false)
    try await repo.undo(swipefileId: "sf1", assetId: "a")
    #expect(try await repo.decisions(for: "sf1").map(\.assetId) == ["a", "b"], "the applied decision stays")
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == counter)
    try await repo.undo(swipefileId: "sf1", assetId: "b")
    #expect(try await repo.decisions(for: "sf1").map(\.assetId) == ["a"])
  }

  /// With a classifier, the undone decision may be baked into it: the counter jumps so that the
  /// next recorded swipe retrains.
  @Test func undoSwipeAfterTrainingMakesTheNextSwipeRetrain() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var sf = Fixtures.swipefile("sf1")
    sf.classifier = SwipefileRecord.encodeClassifier([1, 2, 3])
    try await repo.save(sf)
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .keep, decidedAt: 1))
    #expect(try await repo.undoSwipe(swipefileId: "sf1", assetId: "a", retrainEvery: 5) == true)
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == 4)
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "b", verdict: .keep, decidedAt: 2))
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf1", assetId: "c", verdict: .keep, decidedAt: 3))
    #expect(try await repo.undoSwipe(swipefileId: "sf1", assetId: "b", retrainEvery: 5) == true)
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == 7)  // already due: +1
    #expect(try await repo.undoSwipe(swipefileId: "sf1", assetId: "b", retrainEvery: 5) == false)
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == 7)
  }

  @Test func saveClassifierStoresTheRevisionAndResetsTheSwipeCount() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var sf = Fixtures.swipefile("sf1")
    sf.swipesSinceTrain = 7
    try await repo.save(sf)
    let blob = SwipefileRecord.encodeClassifier([1, 2, 3])
    try await repo.saveClassifier(swipefileId: "sf1", classifier: blob, revision: "r7", consumedSwipes: 7)
    let stored = try #require(try await repo.swipefile(id: "sf1"))
    #expect(stored.classifier == blob && stored.classifierRevision == "r7" && stored.swipesSinceTrain == 0)
    #expect(stored.name == sf.name && stored.prompts == sf.prompts)
  }

  /// Swipes recorded while training ran still count toward the next retrain.
  @Test func saveClassifierSubtractsOnlyTheSwipesItConsumed() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var sf = Fixtures.swipefile("sf1")
    sf.swipesSinceTrain = 7
    try await repo.save(sf)
    let blob = SwipefileRecord.encodeClassifier([1, 2, 3])
    try await repo.saveClassifier(swipefileId: "sf1", classifier: blob, revision: "r1", consumedSwipes: 5)
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == 2)
    try await repo.saveClassifier(swipefileId: "sf1", classifier: blob, revision: "r1", consumedSwipes: 9)
    #expect(try await repo.swipefile(id: "sf1")?.swipesSinceTrain == 0)  // never negative
  }
}
