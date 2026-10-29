#if DEBUG
import Foundation
import GRDB

/// DEBUG-only device QA (docs/qa/): what the Store knows about the library, as counts only. No identifiers and no
/// photo content ever leave this function. Release builds compile none of this file.
public struct QAStoreStats: Codable, Sendable, Equatable {
  public var live = 0
  public var deleted = 0
  public var images = 0
  public var videos = 0
  /// Images with the screenshot subtype bit (`PHAssetMediaSubtype.photoScreenshot`, 1 << 2).
  public var screenshots = 0
  /// Live Photos (1 << 3).
  public var livePhotos = 0
  public var videoSeconds = 0.0
  public var estBytesImages: Int64 = 0
  public var estBytesVideos: Int64 = 0
  public var signalsDone = 0
  public var embedded = 0
  /// Rows the Indexer marked iCloud-only (no local thumbnail).
  public var cloudOnly = 0
  /// Rows that failed `Schema.maxAttempts` loads.
  public var failed = 0
  /// Live rows analysed from a local preview / a full image (v6 `source`).
  public var sourcePreview = 0
  public var sourceFull = 0
  /// Live rows by `AssetRecord.locality`.
  public var onDevice = 0
  public var estBytesOnDevice: Int64 = 0
  /// Live rows by uniform type identifier ("unknown" while not looked up).
  public var byUTI: [String: Int] = [:]

  public init() {}
}

extension Repositories {
  public func qaStats() async throws -> QAStoreStats {
    try await database.writer.read { db in
      var s = QAStoreStats()
      let row = try Row.fetchOne(db, sql: """
        SELECT
          SUM(deleted = 0), SUM(deleted = 1),
          SUM(deleted = 0 AND mediaType = 1), SUM(deleted = 0 AND mediaType = 2),
          SUM(deleted = 0 AND mediaType = 1 AND (subtypes & 4) != 0),
          SUM(deleted = 0 AND mediaType = 1 AND (subtypes & 8) != 0),
          TOTAL(CASE WHEN deleted = 0 AND mediaType = 2 THEN duration ELSE 0 END),
          TOTAL(CASE WHEN deleted = 0 AND mediaType = 1 THEN estBytes ELSE 0 END),
          TOTAL(CASE WHEN deleted = 0 AND mediaType = 2 THEN estBytes ELSE 0 END),
          SUM(deleted = 0 AND signalsDone = 1), SUM(deleted = 0 AND embedded = 1),
          SUM(deleted = 0 AND cloudOnly = 1), SUM(deleted = 0 AND attempts >= \(Schema.maxAttempts)),
          SUM(deleted = 0 AND source = 'preview'), SUM(deleted = 0 AND source = 'full'),
          SUM(deleted = 0 AND originalLocal = 1),
          TOTAL(CASE WHEN deleted = 0 AND originalLocal = 1 THEN estBytes ELSE 0 END)
        FROM asset
        """)
      if let row {
        s.live = row[0] ?? 0; s.deleted = row[1] ?? 0; s.images = row[2] ?? 0; s.videos = row[3] ?? 0
        s.screenshots = row[4] ?? 0; s.livePhotos = row[5] ?? 0; s.videoSeconds = row[6] ?? 0
        s.estBytesImages = Int64((row[7] as Double?) ?? 0); s.estBytesVideos = Int64((row[8] as Double?) ?? 0)
        s.signalsDone = row[9] ?? 0; s.embedded = row[10] ?? 0; s.cloudOnly = row[11] ?? 0; s.failed = row[12] ?? 0
        s.sourcePreview = row[13] ?? 0; s.sourceFull = row[14] ?? 0; s.onDevice = row[15] ?? 0
        s.estBytesOnDevice = Int64((row[16] as Double?) ?? 0)
      }
      for row in try Row.fetchAll(db, sql: "SELECT COALESCE(uti, 'unknown'), COUNT(*) FROM asset WHERE deleted = 0 GROUP BY 1") {
        s.byUTI[row[0]] = row[1]
      }
      return s
    }
  }
}
#endif
