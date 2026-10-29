import Foundation
import GRDB
import Testing
@testable import Store

struct RepositoryTests {
  let repo: Repositories
  let db: AppDatabase

  init() throws {
    db = try AppDatabase.inMemory()
    repo = Repositories(db)
  }

  // MARK: assets

  @Test func pendingAssetsAreNewestFirstAndRespectLimit() async throws {
    try await repo.upsertAssets([
      Fixtures.asset("old", created: 100), Fixtures.asset("new", created: 300), Fixtures.asset("mid", created: 200),
    ])
    #expect(try await repo.pendingAssets(limit: 10).map(\.id) == ["new", "mid", "old"])
    #expect(try await repo.pendingAssets(limit: 2).map(\.id) == ["new", "mid"])
  }

  @Test func pendingMeansNotEmbeddedOrSignalsNotDoneAndNotDeleted() async throws {
    try await repo.upsertAssets([
      Fixtures.asset("none", created: 1),
      Fixtures.asset("embeddedOnly", created: 2, embedded: true, signalsDone: false),
      Fixtures.asset("signalsOnly", created: 3, embedded: false, signalsDone: true),
      Fixtures.asset("complete", created: 4, embedded: true, signalsDone: true),
    ])
    try await repo.markDeleted(["none"])
    #expect(try await repo.pendingAssets(limit: 10).map(\.id) == ["signalsOnly", "embeddedOnly"])
  }

  @Test func upsertInsertsInBatchesAndUpdatesMetadata() async throws {
    let many = (0..<1200).map { Fixtures.asset("a\($0)", created: Double($0)) }
    try await repo.upsertAssets(many)
    #expect(try await repo.assetCount() == 1200)

    var changed = Fixtures.asset("a5", created: 5)
    changed.isFavorite = true
    changed.estBytes = 4242
    try await repo.upsertAssets([changed])
    let stored = try #require(try await repo.asset(id: "a5"))
    #expect(stored.isFavorite)
    #expect(stored.estBytes == 4242)
    #expect(try await repo.assetCount() == 1200)
  }

  @Test func upsertWithNilUTIKeepsTheStoredUTI() async throws {
    // PhotoLibrary.fetchAll() reports uti = nil; a re-sync must not erase a UTI looked up earlier.
    var withUTI = Fixtures.asset("a", created: 1)
    withUTI.uti = "public.jpeg"
    try await repo.upsertAssets([withUTI])
    var fromLibrary = Fixtures.asset("a", created: 2)
    fromLibrary.uti = nil
    try await repo.upsertAssets([fromLibrary])
    var stored = try #require(try await repo.asset(id: "a"))
    #expect(stored.uti == "public.jpeg")
    #expect(stored.created == 2)

    // A non-nil UTI still replaces the stored one (the original resource changed).
    var changed = Fixtures.asset("a", created: 3)
    changed.uti = "public.png"
    try await repo.upsertAssets([changed])
    stored = try #require(try await repo.asset(id: "a"))
    #expect(stored.uti == "public.png")
  }

  @Test func upsertKeepsComputedFieldsAndRevivesDeletedAssets() async throws {
    var done = Fixtures.asset("a", created: 1, embedded: true, signalsDone: true)
    done.blur = 12.5
    done.phash = 0xFFFF_0000_FFFF_0000
    try await repo.replaceAssetsForTesting([done])
    try await repo.markDeleted(["a"])

    // The library re-reports the asset with fresh metadata and empty computed fields.
    try await repo.upsertAssets([Fixtures.asset("a", created: 2, estBytes: 77)])

    let stored = try #require(try await repo.asset(id: "a"))
    #expect(stored.created == 2)
    #expect(stored.estBytes == 77)
    #expect(!stored.deleted)
    #expect(stored.embedded)
    #expect(stored.signalsDone)
    #expect(stored.blur == 12.5)
    #expect(stored.phash == 0xFFFF_0000_FFFF_0000)
  }

  @Test func replaceAssetsForTestingOverwritesEverything() async throws {
    try await repo.upsertAssets([Fixtures.asset("a", created: 1)])
    var r = Fixtures.asset("a", created: 1, embedded: true, signalsDone: true)
    r.featurePrint = Data([1, 2, 3])
    r.aesthetic = 0.25
    r.isUtility = true
    r.sensitive = false
    try await repo.replaceAssetsForTesting([r])
    let stored = try #require(try await repo.asset(id: "a"))
    #expect(stored.featurePrint == Data([1, 2, 3]))
    #expect(stored.aesthetic == 0.25)
    #expect(stored.isUtility == true)
    #expect(stored.sensitive == false)
  }

  @Test func markDeletedHidesFromPendingAndHandlesLargeLists() async throws {
    let many = (0..<2000).map { Fixtures.asset("a\($0)", created: Double($0)) }
    try await repo.upsertAssets(many)
    try await repo.markDeleted(many.map(\.id))
    #expect(try await repo.pendingAssets(limit: 10).isEmpty)
    try await repo.markDeleted([])
  }

  @Test func resetEmbeddedClearsTheFlagOnEveryRowButKeepsSignals() async throws {
    try await repo.replaceAssetsForTesting([
      Fixtures.asset("a", created: 1, embedded: true, signalsDone: true),
      Fixtures.asset("b", created: 2, embedded: true, signalsDone: true),
    ])
    try await repo.resetEmbedded()
    #expect(try await repo.asset(id: "a")?.embedded == false)
    #expect(try await repo.asset(id: "b")?.embedded == false)
    #expect(try await repo.asset(id: "a")?.signalsDone == true)
    #expect(try await repo.pendingAssets(limit: 10).count == 2)
  }

  /// Classifiers were trained on the old vectors: they go in the same transaction as the flags.
  @Test func resetEmbeddedAlsoDropsEveryClassifier() async throws {
    var trained = Fixtures.swipefile("sf1")
    trained.classifier = SwipefileRecord.encodeClassifier([1, 2, 3])
    trained.classifierRevision = "r1"
    trained.swipesSinceTrain = 3
    try await repo.save(trained)
    try await repo.save(Fixtures.swipefile("sf2"))
    try await repo.resetEmbedded()
    for id in ["sf1", "sf2"] {
      let stored = try #require(try await repo.swipefile(id: id))
      #expect(stored.classifier == nil && stored.classifierRevision == nil && stored.swipesSinceTrain == 0)
    }
    #expect(try await repo.swipefile(id: "sf1")?.name == trained.name)
  }

  @Test func phashRoundTripsWithTheHighBitSet() async throws {
    var r = Fixtures.asset("a")
    r.phash = UInt64.max - 5
    try await repo.replaceAssetsForTesting([r])
    #expect(try await repo.asset(id: "a")?.phash == UInt64.max - 5)
  }

  // MARK: commitSignals / markEmbedded

  private func signalAsset() -> AssetRecord {
    var r = Fixtures.asset("a", created: 5, estBytes: 999)
    r.isFavorite = true
    return r
  }

  @Test func commitSignalsWritesOnlySignalColumns() async throws {
    try await repo.upsertAssets([signalAsset(), Fixtures.asset("b", created: 6)])

    try await repo.commitSignals([
      SignalFields(id: "a", signalsDone: true, blur: 3.5, aesthetic: -0.1, isUtility: true, sensitive: false,
                   phash: UInt64.max, featurePrint: Data([9]), cloudOnly: true),
    ])

    let a = try #require(try await repo.asset(id: "a"))
    #expect(a.signalsDone && a.cloudOnly)
    #expect(a.blur == 3.5 && a.aesthetic == -0.1 && a.isUtility == true && a.sensitive == false)
    #expect(a.phash == UInt64.max)
    #expect(a.featurePrint == Data([9]))
    // Library metadata untouched.
    #expect(a.created == 5 && a.estBytes == 999 && a.isFavorite && a.pixelW == 4000 && a.uti == "public.heic")
    #expect(try await repo.asset(id: "b")?.signalsDone == false)
  }

  @Test func commitSignalsNeverChangesEmbedded() async throws {
    try await repo.replaceAssetsForTesting([
      Fixtures.asset("yes", created: 2, embedded: true), Fixtures.asset("no", created: 1, embedded: false),
    ])
    try await repo.commitSignals([SignalFields(id: "yes", signalsDone: true), SignalFields(id: "no", signalsDone: true)])
    #expect(try await repo.asset(id: "yes")?.embedded == true)
    #expect(try await repo.asset(id: "no")?.embedded == false)
  }

  @Test func commitSignalsDoesNotResurrectDeletedAssets() async throws {
    try await repo.upsertAssets([Fixtures.asset("a", created: 1)])
    try await repo.markDeleted(["a"])
    try await repo.commitSignals([SignalFields(id: "a", signalsDone: true)])
    #expect(try await repo.asset(id: "a")?.deleted == true)
  }

  @Test func commitSignalsIgnoresUnknownIdsAndEmptyInput() async throws {
    try await repo.commitSignals([])
    try await repo.commitSignals([SignalFields(id: "ghost", signalsDone: true)])
    #expect(try await repo.assetCount() == 0)
  }

  @Test func markEmbeddedChangesNothingElse() async throws {
    var r = signalAsset()
    r.signalsDone = true; r.blur = 1.5; r.aesthetic = 0.2; r.isUtility = false; r.sensitive = true
    r.phash = 12345; r.featurePrint = Data([1, 2]); r.cloudOnly = true
    try await repo.replaceAssetsForTesting([r, Fixtures.asset("b", created: 1)])

    try await repo.markEmbedded(ids: ["a", "ghost"])

    var expected = r
    expected.embedded = true
    #expect(try await repo.asset(id: "a") == expected)
    #expect(try await repo.asset(id: "b")?.embedded == false)
  }

  @Test func markEmbeddedDoesNotResurrectDeletedAssetsAndHandlesLargeAndEmptyLists() async throws {
    let many = (0..<1500).map { Fixtures.asset("a\($0)", created: Double($0)) }
    try await repo.upsertAssets(many)
    try await repo.markDeleted(["a7"])
    try await repo.markEmbedded(ids: [])
    try await repo.markEmbedded(ids: many.map(\.id))
    #expect(try await repo.embeddedIds().count == 1500)
    #expect(try await repo.asset(id: "a7")?.deleted == true)
  }

  @Test func reEmbeddingAfterAResetKeepsVisionSignals() async throws {
    var r = Fixtures.asset("a", created: 1, embedded: true, signalsDone: true)
    r.blur = 7.5; r.phash = 0xABCD; r.featurePrint = Data([4, 5, 6]); r.aesthetic = 0.4
    try await repo.replaceAssetsForTesting([r])

    try await repo.resetEmbedded()          // model revision changed
    #expect(try await repo.pendingAssets(limit: 10).map(\.id) == ["a"])
    try await repo.markEmbedded(ids: ["a"]) // re-embedding finished

    let a = try #require(try await repo.asset(id: "a"))
    #expect(a.embedded && a.signalsDone)
    #expect(a.blur == 7.5 && a.phash == 0xABCD && a.featurePrint == Data([4, 5, 6]) && a.aesthetic == 0.4)
    #expect(try await repo.pendingAssets(limit: 10).isEmpty)
  }

  // MARK: pending index and ordering

  @Test func pendingTiesBreakById() async throws {
    try await repo.upsertAssets([Fixtures.asset("b", created: 1), Fixtures.asset("a", created: 1), Fixtures.asset("c", created: 2)])
    #expect(try await repo.pendingAssets(limit: 10).map(\.id) == ["c", "a", "b"])
  }

  @Test func pendingQueryUsesThePartialIndex() async throws {
    let plan = try await db.writer.read { db in
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + Repositories.pendingSQL, arguments: [10]).map { $0["detail"] as String }
    }
    #expect(plan.contains { $0.contains("asset_pending") }, "plan was \(plan)")
  }

  // MARK: upsert idempotence

  @Test func upsertIsIdempotent() async throws {
    let batch = (0..<10).map { Fixtures.asset("a\($0)", created: Double($0)) }
    try await repo.upsertAssets(batch)
    try await repo.upsertAssets(batch)
    try await repo.upsertAssets(batch)
    #expect(try await repo.assetCount() == 10)
    #expect(try await repo.asset(id: "a3") == batch[3])
  }

  // MARK: counters

  @Test func consumeCounterAccumulatesAndRefusesOverdraw() async throws {
    #expect(try await repo.consumeCounter(key: "k", n: 3, limit: 5) == 3)
    #expect(try await repo.consumeCounter(key: "k", n: 2, limit: 5) == 5)
    await #expect(throws: CounterError.limitExceeded) { try await repo.consumeCounter(key: "k", n: 1, limit: 5) }
    #expect(try await repo.counter(key: "k") == 5)
  }

  @Test func consumeCounterSurvivesHugeRequests() async throws {
    _ = try await repo.consumeCounter(key: "k", n: 4, limit: 5)
    await #expect(throws: CounterError.limitExceeded) { try await repo.consumeCounter(key: "k", n: Int.max, limit: 5) }
    #expect(try await repo.counter(key: "k") == 4)
  }

  @Test func consumeCounterUpToClampsToTheLimit() async throws {
    #expect(try await repo.consumeCounterUpTo(key: "k", n: 3, limit: 5) == 3)
    #expect(try await repo.consumeCounterUpTo(key: "k", n: 9, limit: 5) == 2)
    #expect(try await repo.consumeCounterUpTo(key: "k", n: 1, limit: 5) == 0)
    #expect(try await repo.consumeCounterUpTo(key: "j", n: -1, limit: 5) == 0)
    #expect(try await repo.counter(key: "k") == 5)
    #expect(try await repo.counter(key: "j") == 0)
  }

  @Test func consumeCounterKeysAreIndependent() async throws {
    _ = try await repo.consumeCounter(key: "a", n: 5, limit: 5)
    #expect(try await repo.consumeCounter(key: "b", n: 1, limit: 5) == 1)
  }

  // MARK: swipefiles

  @Test func swipefileRoundTripsJSONColumnsAndClassifier() async throws {
    var sf = Fixtures.swipefile()
    sf.examples = ["x", "y"]
    let weights = (0..<257).map { Float($0) * 0.5 - 3 }
    sf.classifier = SwipefileRecord.encodeClassifier(weights)
    sf.kind = .preset
    sf.action = .album
    try await repo.save(sf)
    let stored = try #require(try await repo.swipefile(id: "sf1"))
    #expect(stored.prompts == ["a meme", "reaction image"])
    #expect(stored.examples == ["x", "y"])
    #expect(stored.classifier?.count == 257 * 4)
    #expect(SwipefileRecord.decodeClassifier(try #require(stored.classifier)) == weights)
    #expect(stored.kind == .preset)
    #expect(stored.action == .album)

    // Persisted as JSON text, per the schema.
    let raw = try await db.writer.read { try String.fetchOne($0, sql: "SELECT prompts FROM swipefile WHERE id='sf1'") }
    #expect(raw == #"["a meme","reaction image"]"#)
  }

  @Test func classifierDecodingValidatesAgainstDimensions() {
    #expect(SwipefileRecord.classifierLength(dimensions: 256) == 257)
    #expect(SwipefileRecord.decodeClassifier(Data([1, 2, 3])) == nil)
    let for32 = SwipefileRecord.encodeClassifier([Float](repeating: 1, count: 33))
    #expect(SwipefileRecord.decodeClassifier(for32, dimensions: 32)?.count == 33)
    #expect(SwipefileRecord.decodeClassifier(for32, dimensions: 256) == nil)
    #expect(SwipefileRecord.decodeClassifier(for32, dimensions: 31) == nil)
  }

  @Test func swipefileEnumsStoreTheSameTextAsBefore() async throws {
    var sf = Fixtures.swipefile()
    sf.kind = .preset
    sf.action = .squish
    try await repo.save(sf)
    let raw = try await db.writer.read { try String.fetchAll($0, sql: "SELECT kind || ',' || action FROM swipefile") }
    #expect(raw == ["preset,squish"])
  }

  // MARK: decisions

  @Test func recordUndoAndQueued() async throws {
    try await repo.save(Fixtures.swipefile("sf1"))
    try await repo.save(Fixtures.swipefile("sf2"))
    func d(_ sf: String, _ a: String, _ v: Verdict, applied: Bool = false) -> DecisionRecord {
      DecisionRecord(swipefileId: sf, assetId: a, verdict: v, decidedAt: 1, applied: applied)
    }
    try await repo.record(d("sf1", "a", .action))
    try await repo.record(d("sf1", "b", .keep))
    try await repo.record(d("sf1", "c", .album))
    try await repo.record(d("sf1", "d", .action, applied: true))
    try await repo.record(d("sf2", "a", .action))

    #expect(try await repo.decisions(for: "sf1").count == 4)
    #expect(Set(try await repo.queued(for: "sf1").map(\.assetId)) == ["a", "c"])

    try await repo.undo(swipefileId: "sf1", assetId: "a")
    #expect(Set(try await repo.queued(for: "sf1").map(\.assetId)) == ["c"])
    #expect(try await repo.decisions(for: "sf2").count == 1)
  }

  @Test func recordingAgainReplacesTheEarlierVerdict() async throws {
    try await repo.save(Fixtures.swipefile())
    try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .action, decidedAt: 1, applied: false))
    try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .keep, decidedAt: 2, applied: false))
    let all = try await repo.decisions(for: "sf1")
    #expect(all.count == 1)
    #expect(all.first?.verdict == .keep)
  }

  @Test func markAppliedRemovesFromQueue() async throws {
    try await repo.save(Fixtures.swipefile())
    for id in ["a", "b", "c"] {
      try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: id, verdict: .action, decidedAt: 1, applied: false))
    }
    try await repo.markApplied(swipefileId: "sf1", assetIds: ["a", "b"])
    #expect(try await repo.queued(for: "sf1").map(\.assetId) == ["c"])
    #expect(try await repo.decisions(for: "sf1").filter(\.applied).count == 2)
  }

  @Test func recordAppliedMarksDecisionsAcrossSwipefilesAndAssetsDeletedTogether() async throws {
    try await repo.save(Fixtures.swipefile("sf1"))
    try await repo.save(Fixtures.swipefile("sf2"))
    try await repo.upsertAssets([Fixtures.asset("a"), Fixtures.asset("b"), Fixtures.asset("c")])
    for (sf, id) in [("sf1", "a"), ("sf1", "b"), ("sf2", "a"), ("sf2", "c")] {
      try await repo.record(DecisionRecord(swipefileId: sf, assetId: id, verdict: .action, decidedAt: 1))
    }
    let when = Date(timeIntervalSince1970: 1_000)
    try await repo.recordApplied(
      [DecisionKey(swipefileId: "sf1", assetId: "a"), DecisionKey(swipefileId: "sf2", assetId: "a")],
      deletedAssetIds: ["a"], at: when)

    #expect(try await repo.queued(for: "sf1").map(\.assetId) == ["b"])
    #expect(try await repo.queued(for: "sf2").map(\.assetId) == ["c"])
    let a = try #require(try await repo.asset(id: "a"))
    #expect(a.deleted && a.deletedAt == 1_000)
    #expect(try await repo.asset(id: "b")?.deleted == false)
  }

  @Test func recordAppliedCanLeaveAssetsLive() async throws {
    try await repo.save(Fixtures.swipefile())
    try await repo.upsertAssets([Fixtures.asset("a")])
    try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .album, decidedAt: 1))
    try await repo.recordApplied([DecisionKey(swipefileId: "sf1", assetId: "a")], deletedAssetIds: [])
    #expect(try await repo.queued(for: "sf1").isEmpty)
    #expect(try await repo.asset(id: "a")?.deleted == false)
  }

  @Test func recordAppliedHandlesMoreThanOneBatch() async throws {
    try await repo.save(Fixtures.swipefile())
    let ids = (0..<1_203).map { "a\($0)" }
    try await repo.upsertAssets(ids.map { Fixtures.asset($0) })
    for id in ids { try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: id, verdict: .action, decidedAt: 1)) }
    try await repo.recordApplied(ids.map { DecisionKey(swipefileId: "sf1", assetId: $0) }, deletedAssetIds: ids)
    #expect(try await repo.queued(for: "sf1").isEmpty)
    #expect(try await repo.liveEmbeddedIds().isEmpty)
    let live = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset WHERE deleted = 0") }
    #expect(live == 0)
  }
}
