import Foundation
import Testing
@testable import Store

/// Store API used by `Ranking.PhotoSearch`.
struct SearchPoolTests {
  @Test func searchPoolReadsLiveEmbeddedAssetsWithWhatTheAnswerNeeds() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var fav = Fixtures.asset("fav", created: 1_700_000_000, embedded: true, estBytes: 4_200)
    fav.isFavorite = true
    try await repo.replaceAssetsForTesting([
      fav,
      Fixtures.asset("plain", embedded: true),
      Fixtures.asset("unembedded"),
      Fixtures.asset("gone", embedded: true),
    ])
    try await repo.setOriginalLocal(["fav"], local: true)
    try await repo.setOriginalLocal(["plain"], local: false)
    try await repo.markDeleted(["gone"])

    let pool = try await repo.searchPool().sorted { $0.id < $1.id }
    #expect(pool.map(\.id) == ["fav", "plain"])
    #expect(pool[0] == SearchAsset(id: "fav", mediaType: 1, estBytes: 4_200, created: 1_700_000_000, isFavorite: true,
                                   originalLocal: true))
    #expect(pool[1].originalLocal == false)
    #expect(pool[1].created == nil)
  }

  @Test func undecidedKeepsLiveIdsWithNoDecisionInThePile() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(Fixtures.swipefile("sf"))
    try await repo.save(Fixtures.swipefile("other"))
    try await repo.replaceAssetsForTesting(["a", "b", "c", "d"].map { Fixtures.asset($0, embedded: true) })
    try await repo.markDeleted(["d"])
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "sf", assetId: "a", verdict: .keep, decidedAt: 1))
    _ = try await repo.recordSwipe(DecisionRecord(swipefileId: "other", assetId: "b", verdict: .keep, decidedAt: 1))
    #expect(try await repo.undecided(["a", "b", "c", "d", "missing"], in: "sf") == ["b", "c"])
    #expect(try await repo.undecided([], in: "sf").isEmpty)
  }
}
