import Foundation
import Store

/// One library change the committer makes. Each queued decision is settled (marked applied) by exactly one.
public enum CommitOperation: Hashable, Sendable {
  case delete(String)
  case album(name: String, assetId: String)
  case squish(String)

  public var assetId: String {
    switch self {
    case let .delete(id), let .squish(id), let .album(_, id): id
    }
  }
}

/// What applying the queue will do. Built by `CommitPlanner.plan`, carried out by `PhotoKitCommitter.apply`.
public struct CommitPlan: Sendable, Equatable {
  /// Assets to delete, in decision order.
  public var deletes: [String] = []
  /// Album title → assets to add to it, each list in decision order.
  public var albumMoves: [String: [String]] = [:]
  /// Assets to replace with a smaller copy, in decision order.
  public var squishes: [SquishRequest] = []
  /// About how many bytes the deletes free (sum of the estimates). Squish savings aren't included: they
  /// come from the squish planner's estimate and are measured when the squish runs.
  public var estBytes: Int64 = 0
  /// Assets left out because the free quota ran out (not Pro). Their decisions stay queued.
  public var blockedByQuota: Int = 0
  /// The decisions each operation settles once it succeeds. A delete also settles the album and squish
  /// decisions it superseded for the same asset.
  public var settles: [CommitOperation: [DecisionKey]] = [:]
  /// Decisions whose asset is gone from the library (or unknown): nothing to apply, so the committer just
  /// marks them applied, for free.
  public var stale: [DecisionKey] = []
  /// Assets whose delete was dropped because it would have deleted every shot of a protected group (the keeper of a
  /// duplicate group, say, also swiped away in another pile). Their decisions stay queued.
  public var keptLastCopies: [String] = []

  public init() {}

  /// Distinct assets the plan changes: what applying it costs in free quota.
  public var itemCount: Int {
    Set(deletes).union(squishes.map(\.assetID)).union(albumMoves.values.joined()).count
  }

  /// Nothing to apply (stale decisions may still need settling).
  public var isEmpty: Bool { deletes.isEmpty && albumMoves.isEmpty && squishes.isEmpty }
}

public enum CommitPlanner {
  /// Album title used when neither the swipefile's album name nor its name has any text.
  public static let fallbackAlbumName = "Roll"

  /// Turns queued decisions into a plan.
  ///
  /// - `.action` does the swipefile's action; `.album` (an up-swipe) adds to the swipefile's album, or to an
  ///   album named after the swipefile when it has none. `.keep` and applied decisions are ignored.
  /// - Per asset, a delete wins over album moves and squishes (they'd be pointless) and settles them too.
  ///   Album moves and a squish of the same asset both run; the committer adds to albums first, so the
  ///   squished copy inherits the membership.
  /// - Not Pro: assets past `quotaRemaining` are blocked, in order of each asset's first decision.
  ///   Quota counts distinct assets, not decisions.
  /// - Decisions are ordered by `decidedAt`, then swipefile id, then asset id. Decisions of a swipefile
  ///   missing from `swipefiles` are left alone.
  /// - `protecting` lists groups of shots of which at least one must survive (duplicate groups, keeper first). If
  ///   every live member of a group would be deleted, the first one's delete is dropped (`keptLastCopies`); its other
  ///   decisions (album, squish) still apply.
  public static func plan(queued: [DecisionRecord], records: [String: AssetRecord],
                          swipefiles: [String: SwipefileRecord], isPro: Bool, quotaRemaining: Int,
                          protecting groups: [[String]] = []) -> CommitPlan {
    let ordered = queued
      .filter { !$0.applied && $0.verdict != .keep }
      .sorted { ($0.decidedAt, $0.swipefileId, $0.assetId) < ($1.decidedAt, $1.swipefileId, $1.assetId) }

    var plan = CommitPlan()
    // Assets in order of their first decision, and the operation each of their decisions asks for.
    var assetOrder: [String] = []
    var wanted: [String: [(op: CommitOperation, key: DecisionKey)]] = [:]

    for decision in ordered {
      guard let swipefile = swipefiles[decision.swipefileId] else { continue }
      guard let record = records[decision.assetId], !record.deleted else {
        plan.stale.append(decision.key)
        continue
      }
      if wanted[decision.assetId] == nil { assetOrder.append(decision.assetId) }
      wanted[decision.assetId, default: []].append((operation(for: decision, in: swipefile), decision.key))
    }

    for group in groups {
      let live = group.filter { records[$0].map { !$0.deleted } ?? false }
      guard let survivor = live.first,
            live.allSatisfy({ id in wanted[id]?.contains(where: { $0.op == .delete(id) }) ?? false }) else { continue }
      wanted[survivor]?.removeAll { $0.op == .delete(survivor) }
      if wanted[survivor]?.isEmpty ?? true {
        wanted[survivor] = nil
        assetOrder.removeAll { $0 == survivor }
      }
      plan.keptLastCopies.append(survivor)
    }

    let allowed = isPro ? assetOrder.count : min(assetOrder.count, max(0, quotaRemaining))
    plan.blockedByQuota = assetOrder.count - allowed

    for id in assetOrder.prefix(allowed) {
      let entries = wanted[id] ?? []
      if entries.contains(where: { $0.op == .delete(id) }) {
        plan.deletes.append(id)
        plan.estBytes += records[id]?.estBytes ?? 0
        plan.settles[.delete(id)] = entries.map(\.key)
        continue
      }
      for (op, key) in entries {
        if plan.settles[op] == nil {
          switch op {
          case let .album(name, _): plan.albumMoves[name, default: []].append(id)
          case .squish: plan.squishes.append(SquishRequest(assetID: id, estimatedBytes: records[id]?.estBytes ?? 0))
          case .delete: break
          }
        }
        plan.settles[op, default: []].append(key)
      }
    }
    return plan
  }

  private static func operation(for decision: DecisionRecord, in swipefile: SwipefileRecord) -> CommitOperation {
    let id = decision.assetId
    if decision.verdict == .album { return .album(name: albumName(for: swipefile), assetId: id) }
    switch swipefile.action {
    case .delete: return .delete(id)
    case .squish: return .squish(id)
    case .album: return .album(name: albumName(for: swipefile), assetId: id)
    }
  }

  static func albumName(for swipefile: SwipefileRecord) -> String {
    for candidate in [swipefile.albumName, swipefile.name] {
      if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
    }
    return fallbackAlbumName
  }
}
