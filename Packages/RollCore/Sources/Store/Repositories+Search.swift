import Foundation
import GRDB

/// What a photo search reads per asset: enough to rank, refine and describe the answer.
public struct SearchAsset: Sendable, Equatable, Identifiable {
  public var id: String
  public var mediaType: Int
  public var estBytes: Int64
  public var created: Double?
  public var isFavorite: Bool
  /// `AssetRecord.originalLocal`: true when the original is on this iPhone, nil if not checked yet.
  public var originalLocal: Bool?

  public init(id: String, mediaType: Int, estBytes: Int64, created: Double?, isFavorite: Bool, originalLocal: Bool?) {
    self.id = id; self.mediaType = mediaType; self.estBytes = estBytes; self.created = created
    self.isFavorite = isFavorite; self.originalLocal = originalLocal
  }
}

/// Reads used by `Ranking.PhotoSearch`.
extension Repositories {
  /// Every live, embedded asset, in no particular order. Like `rankingCandidates`, one query decoded by column
  /// index, since a search reads the whole library.
  public func searchPool() async throws -> [SearchAsset] {
    try await database.writer.read { db in
      var out: [SearchAsset] = []
      let rows = try Row.fetchCursor(db, sql: """
        SELECT id, mediaType, estBytes, created, isFavorite, originalLocal
        FROM asset WHERE deleted = 0 AND embedded = 1
        """)
      while let row = try rows.next() {
        out.append(SearchAsset(id: row[0], mediaType: row[1], estBytes: row[2], created: row[3], isFavorite: row[4],
                               originalLocal: row[5]))
      }
      return out
    }
  }

  /// The search fields of those of `ids` that are live and embedded, in no particular order. Reads only those rows, in
  /// batches: a search reads the few photos that qualified, not the library.
  public func searchAssets(ids: [String]) async throws -> [SearchAsset] {
    guard !ids.isEmpty else { return [] }
    return try await database.writer.read { db in
      var out: [SearchAsset] = []
      out.reserveCapacity(ids.count)
      for start in stride(from: 0, to: ids.count, by: 500) {
        let batch = Array(ids[start..<min(start + 500, ids.count)])
        let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
        let rows = try Row.fetchCursor(db, sql: """
          SELECT id, mediaType, estBytes, created, isFavorite, originalLocal
          FROM asset WHERE id IN (\(marks)) AND deleted = 0 AND embedded = 1
          """, arguments: StatementArguments(batch))
        while let row = try rows.next() {
          out.append(SearchAsset(id: row[0], mediaType: row[1], estBytes: row[2], created: row[3], isFavorite: row[4],
                                 originalLocal: row[5]))
        }
      }
      return out
    }
  }

  /// Of `ids`, those that are live and have no decision in `swipefileId`. Reads only those rows, in batches.
  public func undecided(_ ids: [String], in swipefileId: String) async throws -> Set<String> {
    guard !ids.isEmpty else { return [] }
    return try await database.writer.read { db in
      var out = Set<String>()
      for start in stride(from: 0, to: ids.count, by: 500) {
        let batch = Array(ids[start..<min(start + 500, ids.count)])
        let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
        let sql = """
          SELECT a.id FROM asset a
          WHERE a.id IN (\(marks)) AND a.deleted = 0
            AND NOT EXISTS (SELECT 1 FROM decision d WHERE d.swipefileId = ? AND d.assetId = a.id)
          """
        out.formUnion(try String.fetchAll(db, sql: sql, arguments: StatementArguments(batch + [swipefileId])))
      }
      return out
    }
  }
}
