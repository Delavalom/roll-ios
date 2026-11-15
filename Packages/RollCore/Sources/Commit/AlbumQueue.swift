import Foundation
import Store

/// "Make album" queues its selection under a hidden system swipefile per album (`__album__/<name>`, action album), so
/// creating it goes through `CommitPlanner` and `PhotoKitCommitter` like every other change: the same quota rule
/// (`FreeQuota.countsAlbumAdds`), Store bookkeeping and progress. A living album (`SavedSearchRecord.swipefileId`)
/// points at the same queue, so photos already added count as decided and aren't offered again.
public enum AlbumQueue {
  public static let prefix = "__album__/"

  public static func swipefileId(album: String) -> String { prefix + normalized(album) }

  public static func swipefile(album: String, created: Double) -> SwipefileRecord {
    let name = normalized(album)
    return SwipefileRecord(id: swipefileId(album: name), name: name, kind: .custom, prompts: [], action: .album,
                           albumName: name, created: created)
  }

  /// Makes the album's queue exactly `ids` (in that order) and returns its swipefile id. Photos this queue already
  /// added (applied decisions) are skipped, so they cost nothing again; queued photos not in `ids` are taken off.
  @discardableResult
  public static func replace(album: String, with ids: [String], repositories: Repositories,
                             now: Double = Date().timeIntervalSince1970) async throws -> String {
    let id = swipefileId(album: album)
    if try await repositories.swipefile(id: id) == nil {
      try await repositories.save(swipefile(album: album, created: now))
    }
    let decisions = try await repositories.decisions(for: id)
    let added = Set(decisions.filter(\.applied).map(\.assetId))
    let wanted = Set(ids)
    for decision in decisions where !decision.applied && !wanted.contains(decision.assetId) {
      try await repositories.undo(swipefileId: id, assetId: decision.assetId)
    }
    var seen = Set<String>()
    for (offset, asset) in ids.enumerated() where !added.contains(asset) && seen.insert(asset).inserted {
      try await repositories.record(DecisionRecord(swipefileId: id, assetId: asset, verdict: .action,
                                                   decidedAt: now + Double(offset) / 1_000_000))
    }
    return id
  }

  /// Marks `ids` as passed over for this album (`.keep`), unless already added, so a living album doesn't offer them
  /// again. Used when the person deselects offered photos.
  public static func pass(album: String, ids: [String], repositories: Repositories,
                          now: Double = Date().timeIntervalSince1970) async throws {
    let id = swipefileId(album: album)
    if try await repositories.swipefile(id: id) == nil {
      try await repositories.save(swipefile(album: album, created: now))
    }
    let added = Set(try await repositories.decisions(for: id).filter(\.applied).map(\.assetId))
    for asset in ids where !added.contains(asset) {
      try await repositories.record(DecisionRecord(swipefileId: id, assetId: asset, verdict: .keep, decidedAt: now))
    }
  }

  static func normalized(_ album: String) -> String {
    let name = album.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? CommitPlanner.fallbackAlbumName : name
  }
}
