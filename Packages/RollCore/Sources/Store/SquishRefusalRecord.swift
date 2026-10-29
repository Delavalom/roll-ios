import Foundation
import GRDB

/// A squish that was refused while running (a format or kind only the file reveals, like Dolby Vision or a CMYK
/// JPEG), remembered so the item stops being offered. It holds while the asset's `modified` date is the one recorded
/// here: once the library reports a different modification date, the item is offered again.
public struct SquishRefusalRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "squishRefusal"

  public var assetId: String
  /// What the UI shows under "Not squishable yet".
  public var reason: String
  /// The asset's `modified` when it was refused (nil when the library hadn't reported one).
  public var modified: Double?
  public var refusedAt: Double

  public init(assetId: String, reason: String, modified: Double?, refusedAt: Double) {
    self.assetId = assetId; self.reason = reason; self.modified = modified; self.refusedAt = refusedAt
  }
}

extension Repositories {
  /// Remembers that squishing `assetId` was refused, with the asset's current `modified` date from the Store (one row
  /// per asset; a later refusal replaces it). Unknown ids are ignored.
  public func recordSquishRefusal(assetId: String, reason: String, at date: Date = Date()) async throws {
    try await database.writer.write { db in
      try db.execute(sql: """
        INSERT OR REPLACE INTO squishRefusal (assetId, reason, modified, refusedAt)
        SELECT id, ?, modified, ? FROM asset WHERE id = ?
        """, arguments: [reason, date.timeIntervalSince1970, assetId])
    }
  }

  /// Refusals that still hold: the asset is live and its `modified` date is unchanged since it was refused.
  public func activeSquishRefusals() async throws -> [SquishRefusalRecord] {
    try await database.writer.read { db in
      try SquishRefusalRecord.fetchAll(db, sql: """
        SELECT r.* FROM squishRefusal r JOIN asset a ON a.id = r.assetId
        WHERE a.deleted = 0 AND a.modified IS r.modified ORDER BY r.assetId
        """)
    }
  }
}
