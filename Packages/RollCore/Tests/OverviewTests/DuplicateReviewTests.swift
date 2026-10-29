import Foundation
import Overview
import Store
import Testing

struct DuplicateReviewTests {
  let repo: Repositories
  let group = DuplicateGroup(id: "a", members: ["a", "b", "c"], keeper: "b", kind: .duplicates, reclaimableBytes: 0)

  init() throws { repo = Repositories(try AppDatabase.inMemory()) }

  @Test func theSystemSwipefileDeletesAndIsHidden() async throws {
    let swipefile = try await DuplicateReview.ensureSwipefile(repositories: repo, now: 7)
    #expect(swipefile.id == SystemSwipefile.duplicatesId)
    #expect(swipefile.action == .delete)
    #expect(SystemSwipefile.isHidden(swipefile))
    // Idempotent: the stored record is returned, not replaced.
    #expect(try await DuplicateReview.ensureSwipefile(repositories: repo, now: 99).created == 7)
  }

  @Test func eachKindHasItsOwnHiddenQueue() async throws {
    let similar = DuplicateGroup(id: "s", members: ["s1", "s2"], keeper: "s1", kind: .similarShots, reclaimableBytes: 0)
    try await DuplicateReview.queue(group, keeper: "b", repositories: repo, now: 1)
    try await DuplicateReview.queue(similar, keeper: "s1", repositories: repo, now: 1)
    #expect(Set(try await repo.queued(for: SystemSwipefile.duplicatesId).map(\.assetId)) == ["a", "c"])
    #expect(try await repo.queued(for: SystemSwipefile.similarShotsId).map(\.assetId) == ["s2"])
    let stored = try #require(try await repo.swipefile(id: SystemSwipefile.similarShotsId))
    #expect(stored.name == "Similar shots" && SystemSwipefile.isHidden(stored))
    try await DuplicateReview.unqueue(similar, repositories: repo)
    #expect(try await repo.queued(for: SystemSwipefile.similarShotsId).isEmpty)
    #expect(try await repo.queued(for: SystemSwipefile.duplicatesId).count == 2)
  }

  @Test func aKeeperOutsideTheGroupQueuesNothing() async throws {
    await #expect(throws: DuplicateReviewError.keeperNotInGroup) {
      try await DuplicateReview.queue(group, keeper: "stranger", repositories: repo, now: 1)
    }
    #expect(try await repo.swipefile(id: SystemSwipefile.duplicatesId) == nil)
  }

  @Test func protectedGroupsPutTheImpliedKeeperFirst() {
    #expect(DuplicateReview.protectedGroups([group], queued: []) == [["b", "a", "c"]])
    #expect(DuplicateReview.protectedGroups([group], queued: ["b", "c"]) == [["a", "b", "c"]])
  }

  @Test func queueingDeletesEveryoneButTheKeeper() async throws {
    try await DuplicateReview.queue(group, keeper: "b", repositories: repo, now: 1)
    let queued = try await repo.queued(for: SystemSwipefile.duplicatesId)
    #expect(Set(queued.map(\.assetId)) == ["a", "c"])
    #expect(queued.allSatisfy { $0.verdict == .action })
  }

  @Test func changingTheKeeperRequeues() async throws {
    try await DuplicateReview.queue(group, keeper: "b", repositories: repo, now: 1)
    try await DuplicateReview.queue(group, keeper: "a", repositories: repo, now: 2)
    let queued = Set(try await repo.queued(for: SystemSwipefile.duplicatesId).map(\.assetId))
    #expect(queued == ["b", "c"])
    #expect(DuplicateReview.keeper(of: group, queued: queued) == "a")
  }

  @Test func keeperFallsBackToTheDefaultUnlessExactlyOneIsLeft() {
    #expect(DuplicateReview.keeper(of: group, queued: []) == "b")
    #expect(DuplicateReview.keeper(of: group, queued: ["a"]) == "b")
    #expect(DuplicateReview.keeper(of: group, queued: ["b", "c"]) == "a")
    #expect(DuplicateReview.isQueued(group, queued: ["b", "c"]))
    #expect(!DuplicateReview.isQueued(group, queued: ["c"]))
  }

  @Test func unqueueRemovesTheGroupsDecisions() async throws {
    try await DuplicateReview.queue(group, keeper: "b", repositories: repo, now: 1)
    try await DuplicateReview.unqueue(group, repositories: repo)
    #expect(try await repo.queued(for: SystemSwipefile.duplicatesId).isEmpty)
  }
}
