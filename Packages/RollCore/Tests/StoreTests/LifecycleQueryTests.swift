import Foundation
import GRDB
import Testing
@testable import Store

/// Deletion dates, vector purge candidates, content resets and failed attempts.
struct LifecycleQueryTests {
  let repo: Repositories
  let db: AppDatabase

  init() throws {
    db = try AppDatabase.inMemory()
    repo = Repositories(db)
  }

  @Test func markDeletedRecordsTheFirstDeletionDateAndUpsertClearsIt() async throws {
    try await repo.upsertAssets([Fixtures.asset("a", created: 1)])
    try await repo.markDeleted(["a"], at: Date(timeIntervalSince1970: 100))
    try await repo.markDeleted(["a"], at: Date(timeIntervalSince1970: 200))
    #expect(try await repo.asset(id: "a")?.deletedAt == 100)
    try await repo.upsertAssets([Fixtures.asset("a", created: 1)])
    let revived = try #require(try await repo.asset(id: "a"))
    #expect(!revived.deleted && revived.deletedAt == nil)
  }

  @Test func deletedEmbeddedIdsAreThePurgeCandidates() async throws {
    try await repo.replaceAssetsForTesting([
      Fixtures.asset("live", embedded: true), Fixtures.asset("goneEmbedded", embedded: true),
      Fixtures.asset("goneBare"),
    ])
    try await repo.markDeleted(["goneEmbedded", "goneBare"])
    #expect(try await repo.deletedEmbeddedIds() == ["goneEmbedded"])
  }

  @Test func resetForContentChangeMakesTheAssetPendingAgain() async throws {
    var a = Fixtures.asset("a", created: 1, embedded: true, signalsDone: true)
    a.cloudOnly = true
    a.attempts = 2
    a.blur = 3
    try await repo.replaceAssetsForTesting([a, Fixtures.asset("b", embedded: true, signalsDone: true)])
    #expect(try await repo.resetForContentChange(ids: ["a"]) == 1)
    let row = try #require(try await repo.asset(id: "a"))
    #expect(!row.signalsDone && !row.embedded && !row.cloudOnly && row.attempts == 0)
    #expect(row.blur == 3, "old signals stay until the new ones are committed")
    #expect(try await repo.asset(id: "b")?.embedded == true)
  }

  @Test func threeFailedAttemptsLeavePendingUntilReset() async throws {
    try await repo.upsertAssets([Fixtures.asset("a", created: 2), Fixtures.asset("b", created: 1)])
    for _ in 0..<2 { try await repo.recordFailedAttempts(ids: ["a"]) }
    #expect(try await repo.pendingAssetIds(includingEmbedding: true, includingCloudOnly: true) == ["a", "b"])
    try await repo.recordFailedAttempts(ids: ["a"])
    #expect(try await repo.asset(id: "a")?.attempts == 3)
    #expect(try await repo.pendingAssetIds(includingEmbedding: true, includingCloudOnly: true) == ["b"])
    #expect(try await repo.pendingAssets(limit: 10).map(\.id) == ["b"])
    #expect(try await repo.failedAssetCount() == 1)

    #expect(try await repo.resetFailures() == 1)
    #expect(try await repo.failedAssetCount() == 0)
    #expect(try await repo.pendingAssetIds(includingEmbedding: true, includingCloudOnly: true) == ["a", "b"])
  }

  @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
  func pendingCountMatchesThePendingIds(embedding: Bool, cloud: Bool) async throws {
    try await repo.replaceAssetsForTesting([
      Fixtures.asset("none", created: 4), Fixtures.asset("signalsOnly", created: 3, signalsDone: true),
      Fixtures.asset("done", created: 2, embedded: true, signalsDone: true),
    ])
    try await repo.commitSignals([SignalFields(id: "none", signalsDone: false, cloudOnly: true)])
    let ids = try await repo.pendingAssetIds(includingEmbedding: embedding, includingCloudOnly: cloud)
    #expect(try await repo.pendingAssetCount(includingEmbedding: embedding, includingCloudOnly: cloud) == ids.count)
    let sql = Repositories.pendingCountSQL(includingEmbedding: embedding, includingCloudOnly: cloud)
    let plan = try await db.writer.read { db in
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
    }
    #expect(plan.contains { $0.contains("asset_pending") }, "plan was \(plan)")
  }
}

struct RankingCandidateLifecycleTests {
  @Test func rankingCandidatesNeverReturnAssetsMarkedDeleted() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf"))
    try await repo.replaceAssetsForTesting([Fixtures.asset("live", embedded: true), Fixtures.asset("gone", embedded: true)])
    try await repo.markDeleted(["gone"])
    for embeddedOnly in [true, false] {
      let ids = try await repo.rankingCandidates(swipefileId: "sf", embeddedOnly: embeddedOnly, filter: .none).map(\.id)
      #expect(ids == ["live"])
    }
  }

  /// An asset whose loads kept failing has no vector, so it never reaches embedding-ranked piles; it is
  /// still a real library item, so metadata presets (large videos, screenshots) may show it.
  @Test func failedAssetsAreOutOfEmbeddedPilesOnly() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf"))
    try await repo.upsertAssets([Fixtures.asset("failed")])
    for _ in 0..<Schema.maxAttempts { try await repo.recordFailedAttempts(ids: ["failed"]) }
    #expect(try await repo.rankingCandidates(swipefileId: "sf", embeddedOnly: true, filter: .none).isEmpty)
    #expect(try await repo.rankingCandidates(swipefileId: "sf", embeddedOnly: false, filter: .none).map(\.id) == ["failed"])
  }
}

struct LiveAssetsTests {
  @Test func liveAssetsAreNewestFirstWithoutDeletedRows() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([
      Fixtures.asset("old", created: 1), Fixtures.asset("new", created: 3), Fixtures.asset("gone", created: 2),
      Fixtures.asset("b", created: 2), Fixtures.asset("a", created: 2),
    ])
    try await repo.markDeleted(["gone"])
    #expect(try await repo.liveAssets().map(\.id) == ["new", "a", "b", "old"])
  }

  @Test func slimLiveAssetsMatchLiveAssetsWithoutFeaturePrints() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var printed = Fixtures.asset("printed", created: 2)
    printed.modified = 9
    try await repo.upsertAssets([printed, Fixtures.asset("plain", created: 1), Fixtures.asset("gone", created: 3)])
    try await repo.commitSignals([SignalFields(id: "printed", signalsDone: true, blur: 12, aesthetic: 0.4, isUtility: true,
                                               sensitive: false, phash: 0xFFFF_0000_FFFF_0000, featurePrint: Data(repeating: 7, count: 3_000))])
    try await repo.markDeleted(["gone"])

    let full = try await repo.liveAssets()
    let slim = try await repo.liveAssetsSlim()
    #expect(full.first?.featurePrint?.count == 3_000)
    #expect(slim.map(\.featurePrint) == [nil, nil])
    #expect(slim == full.map { var r = $0; r.featurePrint = nil; return r }, "every other column is the same")
    #expect(slim.first?.phash == 0xFFFF_0000_FFFF_0000 && slim.first?.modified == 9)
  }
}
