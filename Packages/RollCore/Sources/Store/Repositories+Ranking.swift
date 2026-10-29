import Foundation
import GRDB

/// One live asset as an in-memory ranking pool keeps it (`Repositories.rankingRows`).
public struct RankingRow: Sendable, Equatable {
  public var asset: RankingAsset
  public var embedded: Bool

  public init(asset: RankingAsset, embedded: Bool) {
    self.asset = asset; self.embedded = embedded
  }
}

/// Reads and writes used by `Ranking.SwipefileEngine`.
extension Repositories {
  /// The candidate pool of `swipefileId`: non-deleted assets (only embedded ones if `embeddedOnly`)
  /// that pass `filter` and have no decision in this swipefile yet, in no particular order.
  ///
  /// One query does all of it (the decision check is a `NOT EXISTS` on the decision primary key),
  /// and rows are decoded by column index, since ranking reads the whole library on every call.
  public func rankingCandidates(swipefileId: String, embeddedOnly: Bool, filter: CandidateFilter) async throws -> [RankingAsset] {
    let (clause, filterArguments) = filter.sql
    let sql = """
      SELECT a.id, a.mediaType, a.subtypes, a.estBytes, a.blur, a.aesthetic, a.isUtility, a.sensitive, a.source,
        a.previewSide
      FROM asset a
      WHERE a.deleted = 0\(embeddedOnly ? " AND a.embedded = 1" : "")\(clause)
        AND NOT EXISTS (SELECT 1 FROM decision d WHERE d.swipefileId = ? AND d.assetId = a.id)
      """
    let arguments = filterArguments + [swipefileId]
    return try await database.writer.read { db in
      var out: [RankingAsset] = []
      let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
      while let row = try rows.next() {
        let previewSide: Int? = row[9]
        out.append(RankingAsset(id: row[0], mediaType: row[1], subtypes: row[2], estBytes: row[3], blur: row[4],
                                aesthetic: row[5], isUtility: row[6], sensitive: row[7],
                                qualityTrusted: (previewSide ?? 0) >= AssetRecord.qualityAnalysisSide))
      }
      return out
    }
  }

  /// Every `asset` column ranking reads (`rankingRows`, `rankingCandidates` and `CandidateFilter`). `RankingChanges`
  /// counts updates of exactly these, so a column read here must be listed here.
  public static let rankingColumns = ["id", "mediaType", "subtypes", "estBytes", "blur", "aesthetic", "isUtility",
                                      "sensitive", "previewSide", "deleted", "embedded"]

  /// Starts counting the commits that change what ranking reads (see `RankingChanges`). Observes while the returned
  /// object is alive; read its `generation` before reading rows to stamp them.
  public func observeRankingChanges() async throws -> RankingChanges {
    let changes = RankingChanges()
    try await database.writer.writeWithoutTransaction { db in db.add(transactionObserver: changes) }
    return changes
  }

  /// Every live (non-deleted) asset with the columns ranking needs and its `embedded` flag, in no particular order:
  /// what an in-memory pool keeps, so each pile filters it with `CandidateFilter.matches` instead of SQL.
  public func rankingRows() async throws -> [RankingRow] {
    let sql = """
      SELECT id, mediaType, subtypes, estBytes, blur, aesthetic, isUtility, sensitive, previewSide, embedded
      FROM asset WHERE deleted = 0
      """
    return try await database.writer.read { db in
      var out: [RankingRow] = []
      let rows = try Row.fetchCursor(db, sql: sql)
      while let row = try rows.next() {
        let previewSide: Int? = row[8]
        out.append(RankingRow(
          asset: RankingAsset(id: row[0], mediaType: row[1], subtypes: row[2], estBytes: row[3], blur: row[4],
                              aesthetic: row[5], isUtility: row[6], sensitive: row[7],
                              qualityTrusted: (previewSide ?? 0) >= AssetRecord.qualityAnalysisSide),
          embedded: row[9]))
      }
      return out
    }
  }

  /// The assets with a decision in `swipefileId` (applied or not), in no particular order.
  public func decidedAssetIds(swipefileId: String) async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: "SELECT assetId FROM decision WHERE swipefileId = ?", arguments: [swipefileId])
    }
  }

  /// The verdicts of the `limit` most recent decisions in `swipefileId`, newest first.
  public func recentVerdicts(swipefileId: String, limit: Int) async throws -> [Verdict] {
    try await database.writer.read { db in
      try Verdict.fetchAll(db, sql: "SELECT verdict FROM decision WHERE swipefileId = ? ORDER BY decidedAt DESC LIMIT ?",
                           arguments: [swipefileId, limit])
    }
  }

  /// In one transaction: stores `decision` (replacing an earlier one for the same asset) and adds 1 to
  /// the swipefile's `swipesSinceTrain`. Returns the updated swipefile, or nil (storing nothing) if
  /// the swipefile doesn't exist.
  public func recordSwipe(_ decision: DecisionRecord) async throws -> SwipefileRecord? {
    try await database.writer.write { db in
      guard var swipefile = try SwipefileRecord.fetchOne(db, key: decision.swipefileId) else { return nil }
      try decision.save(db)
      swipefile.swipesSinceTrain += 1
      try swipefile.update(db, columns: ["swipesSinceTrain"])
      return swipefile
    }
  }

  /// In one transaction: deletes the decision and, if there was one, updates `swipesSinceTrain`:
  /// - no classifier yet: takes 1 off (never below 0);
  /// - a classifier exists: the undone decision may be baked into it, so the counter rises to at
  ///   least `retrainEvery - 1` (and by at least 1), which makes the next recorded swipe retrain.
  ///
  /// Only a decision that hasn't been applied is removed. Returns whether a decision was removed.
  @discardableResult
  public func undoSwipe(swipefileId: String, assetId: String, retrainEvery: Int) async throws -> Bool {
    try await database.writer.write { db in
      // An applied decision already changed the library: it can't be taken back.
      let removed = try Self.deleteUnapplied(db, swipefileId, assetId)
      if removed {
        try db.execute(sql: """
          UPDATE swipefile SET swipesSinceTrain = CASE
            WHEN classifier IS NULL THEN MAX(swipesSinceTrain - 1, 0)
            ELSE MAX(swipesSinceTrain + 1, ?)
          END
          WHERE id = ?
          """, arguments: [retrainEvery - 1, swipefileId])
      }
      return removed
    }
  }

  /// Stores a freshly trained classifier (see `SwipefileRecord.encodeClassifier`) with the vector
  /// `revision` it was trained on, and takes `consumedSwipes` (the `swipesSinceTrain` value seen
  /// when training started) off the counter, never below 0, so swipes recorded while training ran
  /// still count toward the next retrain. Touches no other column.
  public func saveClassifier(swipefileId: String, classifier: Data?, revision: String?, consumedSwipes: Int) async throws {
    try await database.writer.write { db in
      try db.execute(sql: """
        UPDATE swipefile SET classifier = ?, classifierRevision = ?, swipesSinceTrain = MAX(swipesSinceTrain - ?, 0)
        WHERE id = ?
        """, arguments: [classifier, revision, consumedSwipes, swipefileId])
    }
  }
}
