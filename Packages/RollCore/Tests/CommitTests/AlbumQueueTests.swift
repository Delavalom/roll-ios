import Entitlements
import Foundation
import Store
import Testing
@testable import Commit

/// "Make album" through the commit path: the hidden per-album queue, and the album quota switch.
struct AlbumQueueTests {
  let db: AppDatabase
  let repo: Repositories

  init() throws {
    db = try AppDatabase.inMemory()
    repo = Repositories(db)
  }

  func plan(_ id: String, isPro: Bool = false, remaining: Int = 50, albumAddsCount: Bool = true) async throws
    -> CommitPlan {
    let queued = try await repo.queued(for: id)
    let records = try await repo.assets(ids: queued.map(\.assetId))
    let swipefiles = try await repo.swipefiles()
    return CommitPlanner.plan(queued: queued, records: CF.byId(records), swipefiles: CF.byId(swipefiles),
                              isPro: isPro, quotaRemaining: remaining, albumAddsCount: albumAddsCount)
  }

  @Test func queuesTheSelectionAsAlbumMovesUnderAHiddenSwipefile() async throws {
    try await repo.upsertAssets(["a", "b", "c"].map { CF.asset($0) })
    let id = try await AlbumQueue.replace(album: "  Soccer ", with: ["b", "a", "b"], repositories: repo, now: 10)
    #expect(id == "__album__/Soccer")
    #expect(id.hasPrefix("__"), "hidden from Swipefiles like the other system queues")
    let stored = try await repo.swipefile(id: id)
    #expect(stored?.action == .album)
    #expect(stored?.albumName == "Soccer")
    #expect(try await repo.queued(for: id).map(\.assetId) == ["b", "a"])
    let p = try await plan(id)
    #expect(p.albumMoves == ["Soccer": ["b", "a"]])
    #expect(p.deletes.isEmpty && p.squishes.isEmpty)
  }

  @Test func replacingDropsDeselectedAndSkipsPhotosAlreadyAdded() async throws {
    try await repo.upsertAssets(["a", "b", "c"].map { CF.asset($0) })
    let id = try await AlbumQueue.replace(album: "Trip", with: ["a", "b"], repositories: repo)
    try await repo.markApplied(swipefileId: id, assetIds: ["a"])
    try await AlbumQueue.replace(album: "Trip", with: ["a", "c"], repositories: repo)
    #expect(try await repo.queued(for: id).map(\.assetId) == ["c"], "b deselected, a already in the album")
  }

  @Test func passedPhotosCountAsDecided() async throws {
    try await repo.upsertAssets(["a", "b"].map { CF.asset($0) })
    let id = try await AlbumQueue.replace(album: "Dog", with: ["a"], repositories: repo)
    try await repo.markApplied(swipefileId: id, assetIds: ["a"])
    try await AlbumQueue.pass(album: "Dog", ids: ["a", "b"], repositories: repo)
    #expect(Set(try await repo.decidedAssetIds(swipefileId: id)) == ["a", "b"])
    #expect(try await repo.queued(for: id).isEmpty, "a keep is never applied")
    #expect(try await repo.decisions(for: id).first { $0.assetId == "a" }?.applied == true, "the add stays history")
  }

  @Test func albumAddsAreFreeByDefaultAndUseTheQuotaOnlyWithTheSwitchOn() async throws {
    #expect(!FreeQuota.countsAlbumAdds, "album adds are free (founder, 2026-11-16)")
    try await repo.upsertAssets(["a", "b", "c"].map { CF.asset($0) })
    let id = try await AlbumQueue.replace(album: "Trip", with: ["a", "b", "c"], repositories: repo)
    let counted = try await plan(id, remaining: 2)
    #expect(counted.albumMoves["Trip"] == ["a", "b"])
    #expect(counted.blockedByQuota == 1)
    let free = try await plan(id, remaining: 0, albumAddsCount: false)
    #expect(free.albumMoves["Trip"] == ["a", "b", "c"])
    #expect(free.blockedByQuota == 0)
    let queued = try await repo.queued(for: id)
    let byDefault = CommitPlanner.plan(
      queued: queued, records: CF.byId(try await repo.assets(ids: queued.map(\.assetId))),
      swipefiles: CF.byId(try await repo.swipefiles()), isPro: false, quotaRemaining: 0)
    #expect(byDefault.albumMoves["Trip"] == ["a", "b", "c"], "the planner's default is the switch: free")
    #expect(byDefault.blockedByQuota == 0)
  }

  @Test func withTheSwitchOffOnlyNonAlbumItemsUseTheQuota() async throws {
    let sf = CF.swipefile("sf"), trip = CF.swipefile("trip", .album, album: "Trip")
    let records = ["a", "b", "c"].map { CF.asset($0) }
    let queued = [CF.decision("trip", "a", at: 0), CF.decision("sf", "b", at: 1), CF.decision("sf", "c", at: 2)]
    let p = CommitPlanner.plan(queued: queued, records: CF.byId(records), swipefiles: CF.byId([sf, trip]),
                               isPro: false, quotaRemaining: 1, albumAddsCount: false)
    #expect(p.albumMoves["Trip"] == ["a"])
    #expect(p.deletes == ["b"])
    #expect(p.blockedByQuota == 1)
  }

  @Test func withTheSwitchOffTheCommitterChargesNothingForAlbumAdds() async throws {
    try await repo.upsertAssets(["a", "b"].map { CF.asset($0) })
    let id = try await AlbumQueue.replace(album: "Trip", with: ["a", "b"], repositories: repo)
    let p = try await plan(id, albumAddsCount: false)
    let log = CallLog()
    let committer = PhotoKitCommitter(library: FakeLibrary(log: log), database: db, pro: FixedPro(value: false),
                                      squish: nil, albumAddsCount: false)
    guard case let .applied(report) = try await committer.apply(p) else { Issue.record("expected applied"); return }
    #expect(report.addedToAlbums == ["Trip": ["a", "b"]])
    #expect(report.quotaSpent == 0)
    #expect(try await FreeQuota(db).remaining() == 50)

    // With the switch on, they're charged.
    try await repo.upsertAssets([CF.asset("c")])
    try await AlbumQueue.replace(album: "Trip", with: ["c"], repositories: repo)
    let counted = PhotoKitCommitter(library: FakeLibrary(log: log), database: db, pro: FixedPro(value: false),
                                    squish: nil, albumAddsCount: true)
    guard case let .applied(second) = try await counted.apply(try await plan(id)) else { return }
    #expect(second.quotaSpent == 1)
  }
}
