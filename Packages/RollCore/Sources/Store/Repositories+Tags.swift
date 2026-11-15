import Foundation
import GRDB

/// Scene labels per photo (Schema v12): the tag pass writes them with `commitTags`, typed search loads them once per
/// tag write with `tagLabels` (`SwipefileEngine.find`, `FindConfig.tags`). Nothing here touches the `asset` table; the
/// tags of a deleted or edited asset go by trigger.
extension Repositories {
  /// Stores what the pass read for each photo (replacing earlier labels), in one transaction. Only the tag tables
  /// change. Ids that are unknown or marked deleted are skipped: a photo deleted while it was read keeps no tags.
  public func commitTags(_ items: [TagFields]) async throws {
    guard !items.isEmpty else { return }
    let now = Date().timeIntervalSince1970
    try await database.writer.write { db in
      let live = try db.cachedStatement(sql: "SELECT 1 FROM asset WHERE id = ? AND deleted = 0")
      let read = try db.cachedStatement(sql: """
        INSERT INTO assetTagRead (assetId, revision, side, readAt) VALUES (?, ?, ?, ?)
        ON CONFLICT(assetId) DO UPDATE SET revision = excluded.revision, side = excluded.side, readAt = excluded.readAt
        """)
      let clear = try db.cachedStatement(sql: "DELETE FROM assetTag WHERE assetId = ?")
      let insert = try db.cachedStatement(sql: """
        INSERT INTO assetTag (assetId, label, confidence) VALUES (?, ?, ?)
        ON CONFLICT(assetId, label) DO UPDATE SET confidence = max(confidence, excluded.confidence)
        """)
      for item in items {
        guard try Bool.fetchOne(live, arguments: [item.id]) == true else { continue }
        try read.execute(arguments: [item.id, item.revision, item.side, now])
        try clear.execute(arguments: [item.id])
        for tag in item.labels where !tag.label.isEmpty {
          try insert.execute(arguments: [item.id, tag.label, tag.confidence])
        }
      }
    }
  }

  /// A photo's labels, best first.
  public func tags(assetId: String) async throws -> [TagLabel] {
    try await database.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT label, confidence FROM assetTag WHERE assetId = ? ORDER BY confidence DESC, label",
                       arguments: [assetId]).map { TagLabel(label: $0[0], confidence: $0[1]) }
    }
  }

  /// Photo id → its labels with confidence >= `minConfidence`, for live photos with at least one. What typed search
  /// folds into a `TagIndex`.
  public func tagLabels(minConfidence: Double) async throws -> [String: [String]] {
    try await database.writer.read { db in
      var out: [String: [String]] = [:]
      let rows = try Row.fetchCursor(db, sql: """
        SELECT t.assetId, t.label FROM assetTag t JOIN asset a ON a.id = t.assetId
        WHERE t.confidence >= ? AND a.deleted = 0
        """, arguments: [minConfidence])
      while let row = try rows.next() { out[row[0] as String, default: []].append(row[1]) }
      return out
    }
  }

  private static func tagCandidateSQL(_ select: String) -> String {
    """
    SELECT \(select) FROM asset INDEXED BY asset_tagOrder WHERE deleted = 0 AND signalsDone = 1
      AND NOT EXISTS (SELECT 1 FROM assetTagRead t WHERE t.assetId = asset.id AND t.revision = :revision
                      AND (t.side IS NOT NULL OR :retryUnread = 0))
    """
  }

  /// Live, analysed photos (videos by their poster frame) not read at `revision`, newest first (ties by id), at most
  /// `limit`. With `retryUnread`, photos recorded unread (no local image last time) count again.
  public func tagCandidateIds(revision: String, retryUnread: Bool, limit: Int) async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: Self.tagCandidateSQL("id") + " ORDER BY created DESC, id LIMIT :limit",
                          arguments: ["revision": revision, "retryUnread": retryUnread, "limit": max(0, limit)])
    }
  }

  /// `COUNT(*)` of what `tagCandidateIds` would return without a limit.
  public func tagCandidateCount(revision: String, retryUnread: Bool) async throws -> Int {
    try await database.writer.read { db in
      try Int.fetchOne(db, sql: Self.tagCandidateSQL("COUNT(*)"),
                       arguments: ["revision": revision, "retryUnread": retryUnread]) ?? 0
    }
  }
}
