import Foundation
import Store

public enum DuplicateReviewError: Error, Equatable {
  /// The keeper isn't one of the group's members: queuing would delete every member.
  case keeperNotInGroup
}

/// Duplicates review (spec §6): the user keeps one shot per group and the others are queued for deletion under a
/// hidden system swipefile, one per kind (`__duplicates__` for exact copies, `__similar__` for similar shots), so the
/// commit sheet, quota and Store bookkeeping are the same as for swipe review, and each screen applies only its own
/// queue.
public enum DuplicateReview {
  public static func swipefileId(for kind: DuplicateGroup.Kind) -> String {
    kind == .duplicates ? SystemSwipefile.duplicatesId : SystemSwipefile.similarShotsId
  }

  public static func swipefile(kind: DuplicateGroup.Kind = .duplicates, created: Double) -> SwipefileRecord {
    SwipefileRecord(id: swipefileId(for: kind), name: kind == .duplicates ? "Duplicates" : "Similar shots",
                    kind: .custom, prompts: [], action: .delete, created: created)
  }

  /// The stored system swipefile for `kind`, created on first use.
  @discardableResult
  public static func ensureSwipefile(kind: DuplicateGroup.Kind = .duplicates, repositories: Repositories,
                                     now: Double = Date().timeIntervalSince1970) async throws -> SwipefileRecord {
    if let stored = try await repositories.swipefile(id: swipefileId(for: kind)) { return stored }
    let record = swipefile(kind: kind, created: now)
    try await repositories.save(record)
    return record
  }

  /// Queues every member but `keeper` for deletion (in the group's kind's queue), and takes any queued decision off
  /// `keeper`. Throws `DuplicateReviewError.keeperNotInGroup` (queuing nothing) if `keeper` isn't a member.
  public static func queue(_ group: DuplicateGroup, keeper: String, repositories: Repositories,
                           now: Double = Date().timeIntervalSince1970) async throws {
    guard group.members.contains(keeper) else { throw DuplicateReviewError.keeperNotInGroup }
    let id = swipefileId(for: group.kind)
    try await ensureSwipefile(kind: group.kind, repositories: repositories, now: now)
    try await repositories.undo(swipefileId: id, assetId: keeper)
    for member in group.members where member != keeper {
      try await repositories.record(DecisionRecord(swipefileId: id, assetId: member, verdict: .action, decidedAt: now))
    }
  }

  /// Takes the group's members off its queue.
  public static func unqueue(_ group: DuplicateGroup, repositories: Repositories) async throws {
    for member in group.members {
      try await repositories.undo(swipefileId: swipefileId(for: group.kind), assetId: member)
    }
  }

  /// The keeper the queue implies: the one member left unqueued when all the others are; otherwise the default.
  public static func keeper(of group: DuplicateGroup, queued: Set<String>) -> String {
    let left = group.members.filter { !queued.contains($0) }
    return left.count == 1 ? left[0] : group.keeper
  }

  /// Every member but one is queued.
  public static func isQueued(_ group: DuplicateGroup, queued: Set<String>) -> Bool {
    group.members.filter { !queued.contains($0) }.count == 1
  }

  /// Each group as `[keeper] + others`, the shape `CommitPlanner.plan(protecting:)` takes, with the keeper the
  /// queues imply (`queued` holds both kinds' queued ids).
  public static func protectedGroups(_ groups: [DuplicateGroup], queued: Set<String>) -> [[String]] {
    groups.map { group in
      let keeper = keeper(of: group, queued: queued)
      return [keeper] + group.members.filter { $0 != keeper }
    }
  }
}
