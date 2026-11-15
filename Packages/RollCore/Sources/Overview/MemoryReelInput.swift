import Dedupe
import Foundation
import Memories
import Signals
import Store

/// A memory video's inputs from what the Store already knows about the photos (no new Vision pass): dates, media type,
/// Vision aesthetics, screenshots and documents, and look-alike groups (`DuplicateGrouper`, keeper by `KeeperPolicy`).
/// `MemoryReelPlanner` picks the shots.
public enum MemoryReelInput {
  /// Screenshot subtype bit (`PHAssetMediaSubtype.photoScreenshot`).
  static let screenshotBit = 1 << 2

  /// One candidate per live, dated photo or video in `records`, in their order.
  public static func candidates(records: [AssetRecord]) -> [ReelCandidate] {
    let live = records.filter { !$0.deleted && $0.created != nil && ($0.mediaType == 1 || $0.mediaType == 2) }
    let groups = DuplicateGrouper.groups(records: live.filter(\.groupable), prepare: FeaturePrints.decode,
                                         distance: { $0.distance(to: $1) })
    return candidates(records: live, groups: groups)
  }

  /// With look-alike groups already made (ids per group).
  public static func candidates(records: [AssetRecord], groups: [[String]]) -> [ReelCandidate] {
    let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var label: [String: String] = [:]
    var keeper: [String: String] = [:]
    for (n, ids) in groups.enumerated() {
      let members = ids.compactMap { byId[$0] }
      guard !members.isEmpty else { continue }
      let pick = KeeperPolicy.keeper(members)
      for id in ids { label[id] = "g\(n)"; keeper[id] = pick }
    }
    return records.compactMap { r in
      guard let created = r.created, !r.deleted, r.mediaType == 1 || r.mediaType == 2 else { return nil }
      return ReelCandidate(id: r.id, created: Date(timeIntervalSince1970: created), isVideo: r.mediaType == 2,
                           duration: r.duration ?? 0, aesthetic: r.aesthetic,
                           isScreenshotOrDocument: r.subtypes & screenshotBit != 0 || r.isUtility == true,
                           similarGroup: label[r.id], isKeeper: label[r.id] == nil || keeper[r.id] == r.id)
    }
  }
}
