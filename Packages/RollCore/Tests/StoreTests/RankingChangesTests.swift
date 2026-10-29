import Foundation
import GRDB
import Testing
@testable import Store

/// `RankingChanges` (the generation an in-memory ranking pool is checked against), `rankingRows` and
/// `decidedAssetIds`.
struct RankingChangesTests {
  private func world() async throws -> (Repositories, RankingChanges) {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    try await repo.upsertAssets([Fixtures.asset("a"), Fixtures.asset("b")])
    return (repo, try await repo.observeRankingChanges())
  }

  @Test func everyWriteRankingCanSeeBumpsTheGeneration() async throws {
    let (repo, changes) = try await world()
    var last = changes.generation
    func bumped() -> Bool { defer { last = changes.generation }; return changes.generation > last }

    try await repo.upsertAssets([Fixtures.asset("c")])
    #expect(bumped(), "a new asset")
    var screenshot = Fixtures.asset("a")
    screenshot.subtypes = 4
    try await repo.upsertAssets([screenshot])
    #expect(bumped(), "library metadata of a stored asset (upsert)")
    try await repo.markEmbedded(ids: ["a"])
    #expect(bumped(), "newly embedded")
    try await repo.commitSignals([SignalFields(id: "a", signalsDone: true, blur: 3)])
    #expect(bumped(), "new signals")
    try await repo.markDeleted(["b"])
    #expect(bumped(), "a deletion")
    _ = try await repo.clearEmbedded(ids: ["a"])
    #expect(bumped(), "flag cleared")
    try await repo.database.writer.write { db in try db.execute(sql: "DELETE FROM asset WHERE id = 'c'") }
    #expect(bumped(), "a row removed")
  }

  @Test func writesRankingCannotSeeLeaveItAlone() async throws {
    let (repo, changes) = try await world()
    let start = changes.generation
    try await repo.setOriginalLocal(["a"], local: true)  // a column ranking never reads
    try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .keep, decidedAt: 1))
    try await repo.markEmbedded(ids: ["missing"])  // matches no row
    struct Boom: Error {}
    _ = try? await repo.database.writer.write { db in
      try db.execute(sql: "UPDATE asset SET blur = 1 WHERE id = 'a'")
      throw Boom()  // rolled back
    }
    #expect(changes.generation == start)
  }

  @Test func rankingRowsAreEveryLiveRowWithItsEmbeddedFlag() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var s = Fixtures.asset("s", embedded: true)
    s.blur = 3; s.aesthetic = -0.5; s.isUtility = true; s.subtypes = 4; s.estBytes = 77; s.previewSide = 300
    try await repo.replaceAssetsForTesting([
      s, Fixtures.asset("plain"), { var d = Fixtures.asset("gone", embedded: true); d.deleted = true; return d }(),
    ])
    let rows = try await repo.rankingRows()
    #expect(Set(rows.map(\.asset.id)) == ["s", "plain"])
    #expect(rows.first { $0.asset.id == "s" } == RankingRow(asset: RankingAsset(s), embedded: true))
    #expect(rows.first { $0.asset.id == "plain" }?.embedded == false)
  }

  @Test func decidedAssetIdsArePerSwipefile() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf1"))
    try await repo.save(Fixtures.swipefile("sf2"))
    try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: "x", verdict: .keep, decidedAt: 1))
    try await repo.record(DecisionRecord(swipefileId: "sf2", assetId: "y", verdict: .action, decidedAt: 2))
    #expect(try await repo.decidedAssetIds(swipefileId: "sf1") == ["x"])
    #expect(try await repo.decidedAssetIds(swipefileId: "none").isEmpty)
  }
}
