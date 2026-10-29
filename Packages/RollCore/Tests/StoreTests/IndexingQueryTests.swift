import Foundation
import GRDB
import Testing
@testable import Store

/// The read paths the Indexer uses: pending id snapshots, page reads and the sync reference list.
struct IndexingQueryTests {
  let repo: Repositories
  let db: AppDatabase

  init() throws {
    db = try AppDatabase.inMemory()
    repo = Repositories(db)
  }

  private func seed() async throws {
    try await repo.replaceAssetsForTesting([
      Fixtures.asset("none", created: 5),
      Fixtures.asset("signalsOnly", created: 4, embedded: false, signalsDone: true),
      Fixtures.asset("embeddedOnly", created: 3, embedded: true, signalsDone: false),
      Fixtures.asset("complete", created: 2, embedded: true, signalsDone: true),
      Fixtures.asset("gone", created: 1),
    ])
    try await repo.markDeleted(["gone"])
  }

  @Test func pendingIdsWithEmbeddingMatchPendingAssets() async throws {
    try await seed()
    let ids = try await repo.pendingAssetIds(includingEmbedding: true, includingCloudOnly: true)
    #expect(ids == ["none", "signalsOnly", "embeddedOnly"])
    #expect(ids == (try await repo.pendingAssets(limit: 10)).map(\.id))
  }

  @Test func pendingIdsWithoutEmbeddingOnlyNeedSignals() async throws {
    try await seed()
    #expect(try await repo.pendingAssetIds(includingEmbedding: false, includingCloudOnly: true) == ["none", "embeddedOnly"])
  }

  @Test func pendingIdsCanSkipCloudOnlyAssets() async throws {
    try await seed()
    try await repo.commitSignals([SignalFields(id: "none", signalsDone: false, cloudOnly: true)])
    #expect(try await repo.pendingAssetIds(includingEmbedding: true, includingCloudOnly: false) == ["signalsOnly", "embeddedOnly"])
    #expect(try await repo.pendingAssetIds(includingEmbedding: true, includingCloudOnly: true).first == "none")
  }

  @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
  func pendingIdQueriesUseThePartialIndex(embedding: Bool, cloud: Bool) async throws {
    let sql = Repositories.pendingIdsSQL(includingEmbedding: embedding, includingCloudOnly: cloud)
    let plan = try await db.writer.read { db in
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
    }
    #expect(plan.contains { $0.contains("asset_pending") }, "plan was \(plan)")
  }

  @Test func assetsByIdKeepTheRequestedOrderAndSkipUnknownIds() async throws {
    try await seed()
    let records = try await repo.assets(ids: ["complete", "missing", "none", "gone"])
    #expect(records.map(\.id) == ["complete", "none", "gone"])
    #expect(try await repo.assets(ids: []).isEmpty)
  }

  @Test func assetsByIdHandleLargeLists() async throws {
    try await repo.upsertAssets((0..<1200).map { Fixtures.asset("a\($0)", created: Double($0)) })
    let ids = (0..<1200).reversed().map { "a\($0)" }
    #expect(try await repo.assets(ids: ids).map(\.id) == ids)
  }

  @Test func assetRefsReportUTIAndDeletedForAllOrSomeIds() async throws {
    try await seed()
    var png = Fixtures.asset("png", created: 9)
    png.uti = "public.png"
    var noUTI = Fixtures.asset("noUTI", created: 8)
    noUTI.uti = nil
    try await repo.upsertAssets([png, noUTI])

    let all = try await repo.assetRefs()
    #expect(all.count == 7)
    let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    #expect(byId["png"] == AssetRef(id: "png", uti: "public.png", deleted: false))
    #expect(byId["noUTI"] == AssetRef(id: "noUTI", uti: nil, deleted: false))
    #expect(byId["gone"]?.deleted == true)

    let some = try await repo.assetRefs(ids: ["png", "missing"])
    #expect(some == [AssetRef(id: "png", uti: "public.png", deleted: false)])
  }
}
