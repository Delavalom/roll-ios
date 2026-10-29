import Testing
import Store
@testable import Commit

struct CommitPlannerTests {
  func plan(_ queued: [DecisionRecord], assets: [AssetRecord], swipefiles: [SwipefileRecord],
            isPro: Bool = true, quotaRemaining: Int = 0) -> CommitPlan {
    CommitPlanner.plan(queued: queued, records: CF.byId(assets), swipefiles: CF.byId(swipefiles),
                       isPro: isPro, quotaRemaining: quotaRemaining)
  }

  @Test func aProtectedGroupNeverLosesEveryShot() {
    // The duplicates queue deletes b and c (keeping a); a was also swiped away in another pile, and filed in an album.
    let queued = [CF.decision("dups", "b", at: 1), CF.decision("dups", "c", at: 1), CF.decision("memes", "a", at: 2),
                  CF.decision("trip", "a", .album, at: 3), CF.decision("memes", "x", at: 4)]
    let assets = ["a", "b", "c", "x"].map { CF.asset($0, bytes: 10) }
    let swipefiles = [CF.swipefile("dups"), CF.swipefile("memes"), CF.swipefile("trip", .album, album: "Trip")]
    let p = CommitPlanner.plan(queued: queued, records: CF.byId(assets), swipefiles: CF.byId(swipefiles), isPro: false,
                               quotaRemaining: 10, protecting: [["a", "b", "c"]])
    #expect(p.deletes == ["b", "c", "x"])
    #expect(p.keptLastCopies == ["a"])
    #expect(p.albumMoves == ["Trip": ["a"]], "its album move still applies")
    #expect(p.settles[.delete("a")] == nil && p.settles[.album(name: "Trip", assetId: "a")] != nil)

    // A group with a live member nobody deletes is left alone; members gone from the library don't count.
    let fine = CommitPlanner.plan(queued: queued, records: CF.byId(assets + [CF.asset("q")]),
                                  swipefiles: CF.byId(swipefiles), isPro: true, quotaRemaining: 0,
                                  protecting: [["a", "q"], ["gone", "x"]])
    #expect(fine.keptLastCopies == ["x"], "x is the only live member of its group")
    #expect(fine.deletes == ["b", "c", "a"])
  }

  @Test func aDroppedLastCopyCostsNoQuota() {
    let queued = [CF.decision("dups", "b", at: 1), CF.decision("memes", "a", at: 2), CF.decision("memes", "x", at: 3)]
    let assets = ["a", "b", "x"].map { CF.asset($0) }
    let p = CommitPlanner.plan(queued: queued, records: CF.byId(assets),
                               swipefiles: CF.byId([CF.swipefile("dups"), CF.swipefile("memes")]), isPro: false,
                               quotaRemaining: 2, protecting: [["a", "b"]])
    #expect(p.deletes == ["b", "x"] && p.blockedByQuota == 0 && p.keptLastCopies == ["a"])
  }

  @Test func emptyQueueGivesAnEmptyPlan() {
    let p = plan([], assets: [], swipefiles: [])
    #expect(p.isEmpty)
    #expect(p.itemCount == 0 && p.blockedByQuota == 0 && p.estBytes == 0)
  }

  @Test func deleteActionsBecomeDeletesInDecisionOrderWithTheirBytes() {
    let p = plan([CF.decision("sf", "b", at: 2), CF.decision("sf", "a", at: 1), CF.decision("sf", "c", at: 3)],
                 assets: [CF.asset("a", bytes: 10), CF.asset("b", bytes: 20), CF.asset("c", bytes: 30)],
                 swipefiles: [CF.swipefile("sf")])
    #expect(p.deletes == ["a", "b", "c"])
    #expect(p.estBytes == 60)
    #expect(p.albumMoves.isEmpty && p.squishes.isEmpty)
    #expect(p.settles[.delete("b")] == [CF.key("sf", "b")])
    #expect(p.itemCount == 3)
  }

  @Test func tiesOnDecisionTimeAreBrokenBySwipefileThenAsset() {
    let p = plan([CF.decision("sf2", "a", at: 1), CF.decision("sf1", "c", at: 1), CF.decision("sf1", "b", at: 1)],
                 assets: [CF.asset("a"), CF.asset("b"), CF.asset("c")],
                 swipefiles: [CF.swipefile("sf1"), CF.swipefile("sf2")])
    #expect(p.deletes == ["b", "c", "a"])
  }

  @Test func squishActionsBecomeSquishRequestsCarryingTheEstimate() {
    let p = plan([CF.decision("big", "v1", at: 1), CF.decision("big", "v2", at: 2)],
                 assets: [CF.asset("v1", bytes: 900, mediaType: 2), CF.asset("v2", bytes: 400, mediaType: 2)],
                 swipefiles: [CF.swipefile("big", .squish)])
    #expect(p.squishes == [SquishRequest(assetID: "v1", estimatedBytes: 900), SquishRequest(assetID: "v2", estimatedBytes: 400)])
    #expect(p.deletes.isEmpty)
    #expect(p.estBytes == 0, "estBytes counts deletes only; squish savings are the squish planner's estimate")
    #expect(p.settles[.squish("v2")] == [CF.key("big", "v2")])
  }

  @Test func albumActionMovesToTheSwipefilesAlbum() {
    let p = plan([CF.decision("trip", "a"), CF.decision("trip", "b", at: 1)],
                 assets: [CF.asset("a"), CF.asset("b")],
                 swipefiles: [CF.swipefile("trip", .album, name: "Trip pile", album: "  Japan 2026 ")])
    #expect(p.albumMoves == ["Japan 2026": ["a", "b"]])
    #expect(p.settles[.album(name: "Japan 2026", assetId: "a")] == [CF.key("trip", "a")])
    #expect(p.estBytes == 0)
  }

  @Test func upSwipeOnADeletePileGoesToItsAlbumOrElseItsName() {
    let p = plan([CF.decision("memes", "a", .album), CF.decision("docs", "b", .album, at: 1),
                  CF.decision("blank", "c", .album, at: 2)],
                 assets: [CF.asset("a"), CF.asset("b"), CF.asset("c")],
                 swipefiles: [CF.swipefile("memes", name: "Memes", album: "Keepers"), CF.swipefile("docs", name: " Docs "),
                              CF.swipefile("blank", name: "  ", album: " ")])
    #expect(p.albumMoves == ["Keepers": ["a"], "Docs": ["b"], CommitPlanner.fallbackAlbumName: ["c"]])
    #expect(p.deletes.isEmpty)
  }

  @Test func keepAndAlreadyAppliedDecisionsAreIgnored() {
    let p = plan([CF.decision("sf", "a", .keep), CF.decision("sf", "b", applied: true), CF.decision("sf", "c")],
                 assets: [CF.asset("a"), CF.asset("b"), CF.asset("c")], swipefiles: [CF.swipefile("sf")])
    #expect(p.deletes == ["c"])
    #expect(p.stale.isEmpty)
  }

  @Test func decisionsForGoneOrUnknownAssetsAreStaleAndCostNothing() {
    let p = plan([CF.decision("sf", "gone"), CF.decision("sf", "unknown", at: 1), CF.decision("sf", "live", at: 2)],
                 assets: [CF.asset("gone", deleted: true), CF.asset("live")], swipefiles: [CF.swipefile("sf")],
                 isPro: false, quotaRemaining: 1)
    #expect(p.deletes == ["live"])
    #expect(p.stale == [CF.key("sf", "gone"), CF.key("sf", "unknown")])
    #expect(p.blockedByQuota == 0)
  }

  @Test func decisionsOfAnUnknownSwipefileAreLeftAlone() {
    let p = plan([CF.decision("nope", "a")], assets: [CF.asset("a")], swipefiles: [])
    #expect(p.isEmpty)
    #expect(p.stale.isEmpty)
  }

  @Test func aDeleteSupersedesAlbumAndSquishForTheSameAsset() {
    let p = plan([CF.decision("trip", "a", at: 1), CF.decision("big", "a", at: 2), CF.decision("memes", "a", at: 3)],
                 assets: [CF.asset("a", bytes: 77)],
                 swipefiles: [CF.swipefile("trip", .album, album: "Trip"), CF.swipefile("big", .squish),
                              CF.swipefile("memes")])
    #expect(p.deletes == ["a"])
    #expect(p.albumMoves.isEmpty && p.squishes.isEmpty)
    #expect(Set(p.settles[.delete("a")] ?? []) == [CF.key("trip", "a"), CF.key("big", "a"), CF.key("memes", "a")])
    #expect(p.itemCount == 1)
    #expect(p.estBytes == 77)
  }

  @Test func albumAndSquishOfOneAssetBothRunAndCountOnce() {
    let p = plan([CF.decision("trip", "v", at: 1), CF.decision("big", "v", at: 2)],
                 assets: [CF.asset("v", mediaType: 2)],
                 swipefiles: [CF.swipefile("trip", .album, album: "Trip"), CF.swipefile("big", .squish)],
                 isPro: false, quotaRemaining: 1)
    #expect(p.albumMoves == ["Trip": ["v"]])
    #expect(p.squishes.map(\.assetID) == ["v"])
    #expect(p.itemCount == 1)
    #expect(p.blockedByQuota == 0)
  }

  @Test func oneAssetQueuedForTheSameAlbumTwiceIsAddedOnce() {
    let p = plan([CF.decision("s1", "a", .album), CF.decision("s2", "a", .album, at: 1)],
                 assets: [CF.asset("a")],
                 swipefiles: [CF.swipefile("s1", album: "Keep"), CF.swipefile("s2", album: "Keep")])
    #expect(p.albumMoves == ["Keep": ["a"]])
    #expect(p.settles[.album(name: "Keep", assetId: "a")] == [CF.key("s1", "a"), CF.key("s2", "a")])
  }

  @Test func oneAssetInTwoAlbumsIsAddedToBoth() {
    let p = plan([CF.decision("s1", "a", .album), CF.decision("s2", "a", .album, at: 1)],
                 assets: [CF.asset("a")],
                 swipefiles: [CF.swipefile("s1", album: "One"), CF.swipefile("s2", album: "Two")])
    #expect(p.albumMoves == ["One": ["a"], "Two": ["a"]])
    #expect(p.itemCount == 1)
  }

  // MARK: quota

  @Test func withoutProEverythingPastTheRemainingQuotaIsBlocked() {
    let p = plan((0..<5).map { CF.decision("sf", "a\($0)", at: Double($0)) },
                 assets: (0..<5).map { CF.asset("a\($0)", bytes: 10) }, swipefiles: [CF.swipefile("sf")],
                 isPro: false, quotaRemaining: 2)
    #expect(p.deletes == ["a0", "a1"])
    #expect(p.blockedByQuota == 3)
    #expect(p.estBytes == 20)
    #expect(p.settles[.delete("a2")] == nil)
  }

  @Test func quotaCountsAssetsNotDecisions() {
    let p = plan([CF.decision("s1", "a", at: 1), CF.decision("s2", "a", at: 2), CF.decision("s1", "b", at: 3)],
                 assets: [CF.asset("a"), CF.asset("b")], swipefiles: [CF.swipefile("s1"), CF.swipefile("s2")],
                 isPro: false, quotaRemaining: 1)
    #expect(p.deletes == ["a"])
    #expect(p.blockedByQuota == 1)
  }

  @Test func blockingFollowsEachAssetsFirstDecision() {
    // b's first decision comes first, so b gets the one free slot even though its delete is decided later.
    let p = plan([CF.decision("trip", "b", at: 1), CF.decision("sf", "a", at: 2), CF.decision("sf", "b", at: 3)],
                 assets: [CF.asset("a"), CF.asset("b")],
                 swipefiles: [CF.swipefile("sf"), CF.swipefile("trip", .album, album: "Trip")],
                 isPro: false, quotaRemaining: 1)
    #expect(p.deletes == ["b"])
    #expect(p.blockedByQuota == 1)
  }

  @Test func zeroOrNegativeQuotaBlocksEverything() {
    for remaining in [0, -4] {
      let p = plan([CF.decision("sf", "a")], assets: [CF.asset("a")], swipefiles: [CF.swipefile("sf")],
                   isPro: false, quotaRemaining: remaining)
      #expect(p.isEmpty)
      #expect(p.blockedByQuota == 1)
    }
  }

  @Test func proIgnoresTheQuota() {
    let p = plan((0..<3).map { CF.decision("sf", "a\($0)", at: Double($0)) },
                 assets: (0..<3).map { CF.asset("a\($0)") }, swipefiles: [CF.swipefile("sf")],
                 isPro: true, quotaRemaining: 0)
    #expect(p.deletes.count == 3)
    #expect(p.blockedByQuota == 0)
  }

  @Test func quotaExactlyCoveringTheQueueBlocksNothing() {
    let p = plan([CF.decision("sf", "a"), CF.decision("sf", "b", at: 1)], assets: [CF.asset("a"), CF.asset("b")],
                 swipefiles: [CF.swipefile("sf")], isPro: false, quotaRemaining: 2)
    #expect(p.deletes == ["a", "b"])
    #expect(p.blockedByQuota == 0)
  }
}
