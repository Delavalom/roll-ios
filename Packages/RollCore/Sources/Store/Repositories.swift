import Foundation
import GRDB

/// Async read/write access to the Store tables.
public enum CounterError: Error, Equatable {
  case limitExceeded
}

public struct Repositories: Sendable {
  let database: AppDatabase
  private static let batchSize = 500

  public init(_ database: AppDatabase) {
    self.database = database
  }

  // MARK: - Assets

  private static let libraryColumns = [
    "mediaType", "subtypes", "created", "pixelW", "pixelH", "duration", "isFavorite", "burstId", "uti", "estBytes",
    "modified",
  ]
  private static let allColumns = ["id"] + libraryColumns + [
    "cloudOnly", "embedded", "signalsDone", "blur", "aesthetic", "isUtility", "sensitive", "phash", "featurePrint", "deleted",
    "deletedAt", "attempts", "source", "previewSide", "originalLocal",
  ]

  /// `uti` is the one library column that can arrive empty: `PhotoLibrary.fetchAll()` returns `uti: nil`
  /// (resource lookups are slow), so a nil must not erase a UTI stored earlier. Everything else is
  /// overwritten by the library's current value.
  private static func updateAssignment(_ column: String) -> String {
    column == "uti" ? "uti = COALESCE(excluded.uti, asset.uti)" : "\(column) = excluded.\(column)"
  }

  private static let upsertSQL = """
    INSERT INTO asset (\(allColumns.joined(separator: ", ")))
    VALUES (\(allColumns.map { ":" + $0 }.joined(separator: ", ")))
    ON CONFLICT(id) DO UPDATE SET \(libraryColumns.map(updateAssignment).joined(separator: ", ")), deleted = 0,
      deletedAt = NULL
    """

  /// Idempotent: inserts new assets as given; for assets already stored, overwrites only the
  /// library-owned metadata (a nil `uti` keeps the stored one) and clears `deleted`, so computed signals
  /// and the `embedded` flag survive a re-sync. Runs in batches of 500, one transaction each.
  public func upsertAssets(_ records: [AssetRecord]) async throws {
    for start in stride(from: 0, to: records.count, by: Self.batchSize) {
      let batch = Array(records[start..<min(start + Self.batchSize, records.count)])
      try await database.writer.write { db in
        let statement = try db.cachedStatement(sql: Self.upsertSQL)
        for record in batch {
          try statement.execute(arguments: StatementArguments(record.databaseDictionary))
        }
      }
    }
  }

  /// Overwrites whole rows (inserting missing ones), including `deleted`. For fixtures only:
  /// production code commits signals with `commitSignals` and flags with `markEmbedded`.
  func replaceAssetsForTesting(_ records: [AssetRecord]) async throws {
    for start in stride(from: 0, to: records.count, by: Self.batchSize) {
      let batch = Array(records[start..<min(start + Self.batchSize, records.count)])
      try await database.writer.write { db in
        for record in batch { try record.save(db) }
      }
    }
  }

  /// Writes the Vision signal columns for each id, in one transaction, and nothing else:
  /// `embedded`, `deleted` and the library metadata are never touched. Unknown ids are ignored.
  /// Safe to call at any cadence, and safe after `resetEmbedded()`: re-embedding never erases signals.
  public func commitSignals(_ updates: [SignalFields]) async throws {
    guard !updates.isEmpty else { return }
    try await database.writer.write { db in
      let statement = try db.cachedStatement(sql: """
        UPDATE asset SET signalsDone = :signalsDone, blur = :blur, aesthetic = :aesthetic, isUtility = :isUtility,
          sensitive = :sensitive, phash = :phash, featurePrint = :featurePrint, cloudOnly = :cloudOnly, source = :source,
          previewSide = :previewSide
        WHERE id = :id
        """)
      for u in updates {
        try statement.execute(arguments: [
          "id": u.id, "signalsDone": u.signalsDone, "blur": u.blur, "aesthetic": u.aesthetic,
          "isUtility": u.isUtility, "sensitive": u.sensitive, "phash": u.phash.map { Int64(bitPattern: $0) },
          "featurePrint": u.featurePrint, "cloudOnly": u.cloudOnly, "source": u.source, "previewSide": u.previewSide,
        ])
      }
    }
  }

  /// Sets only `embedded = 1` for the given ids, all in one transaction. Call it after the vector file
  /// holding those vectors has been saved (see `VectorStore`). Unknown ids are ignored.
  public func markEmbedded(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    try await database.writer.write { db in
      for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
        let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
        _ = try AssetRecord.filter(keys: batch).updateAll(db, Column("embedded").set(to: true))
      }
    }
  }

  public func asset(id: String) async throws -> AssetRecord? {
    try await database.writer.read { db in try AssetRecord.fetchOne(db, key: id) }
  }

  public func assetCount() async throws -> Int {
    try await database.writer.read { db in try AssetRecord.fetchCount(db) }
  }

  /// Must stay structurally identical to the `asset_pending` partial index's WHERE clause
  /// (see `Schema`), with literals rather than bound values, or SQLite can't use the index.
  static let pendingWhere = "deleted = 0 AND attempts < \(Schema.maxAttempts) AND (embedded = 0 OR signalsDone = 0)"

  static let pendingSQL = "SELECT * FROM asset WHERE \(pendingWhere) ORDER BY created DESC, id LIMIT ?"

  /// Live assets that still need an embedding or Vision signals, newest first (ties by id). Assets with
  /// `Schema.maxAttempts` failed loads are left out.
  public func pendingAssets(limit: Int) async throws -> [AssetRecord] {
    try await database.writer.read { db in
      try AssetRecord.fetchAll(db, sql: Self.pendingSQL, arguments: [limit])
    }
  }

  /// The pending-id query for the Indexer. It keeps `pendingSQL`'s WHERE terms literally and only ANDs
  /// extra terms onto them, so SQLite can still use the `asset_pending` partial index.
  static func pendingIdsSQL(includingEmbedding: Bool, includingCloudOnly: Bool) -> String {
    "SELECT id FROM asset WHERE " + pendingFilter(includingEmbedding, includingCloudOnly) + " ORDER BY created DESC, id"
  }

  static func pendingCountSQL(includingEmbedding: Bool, includingCloudOnly: Bool) -> String {
    "SELECT COUNT(*) FROM asset INDEXED BY asset_pending WHERE " + pendingFilter(includingEmbedding, includingCloudOnly)
  }

  private static func pendingFilter(_ includingEmbedding: Bool, _ includingCloudOnly: Bool) -> String {
    var sql = pendingWhere
    if !includingEmbedding { sql += " AND signalsDone = 0" }
    // A cloud-only row with a local preview can still be embedded from that preview without the network.
    if !includingCloudOnly { sql += " AND (cloudOnly = 0 OR source IS NOT NULL)" }
    return sql
  }

  /// Records the result of checking whether the originals of `ids` are on the device (`AssetRecord.locality`). Nothing
  /// else changes. Unknown ids are ignored.
  public func setOriginalLocal(_ ids: [String], local: Bool) async throws {
    guard !ids.isEmpty else { return }
    try await database.writer.write { db in
      for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
        let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
        _ = try AssetRecord.filter(keys: batch).updateAll(db, Column("originalLocal").set(to: local))
      }
    }
  }

  /// Live photos without a looked-up file type that are at least `minPixels` and have none of `excludingSubtypes`,
  /// largest first: the photos whose type decides Squish candidacy and the size estimate (`Indexer.resolveTypes`).
  public func typeLookupCandidates(minPixels: Int, excludingSubtypes: Int, limit: Int) async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: """
        SELECT id FROM asset
        WHERE deleted = 0 AND mediaType = 1 AND uti IS NULL AND COALESCE(pixelW, 0) * COALESCE(pixelH, 0) >= ?
          AND (subtypes & ?) = 0
        ORDER BY COALESCE(pixelW, 0) * COALESCE(pixelH, 0) DESC, created DESC, id LIMIT ?
        """, arguments: [minPixels, excludingSubtypes, limit])
    }
  }

  /// Stores looked-up file types ("" when the library reported none, so it isn't asked again) and the size estimates
  /// that follow from them. Nothing else changes.
  public func updateTypes(_ updates: [(id: String, uti: String, estBytes: Int64)]) async throws {
    guard !updates.isEmpty else { return }
    try await database.writer.write { db in
      let statement = try db.cachedStatement(sql: "UPDATE asset SET uti = ?, estBytes = ? WHERE id = ?")
      for u in updates { try statement.execute(arguments: [u.uti, u.estBytes, u.id]) }
    }
  }

  /// Live rows analysed from a local preview (their originals are in iCloud), newest first: the work of the opt-in
  /// "Improve with iCloud originals" pass.
  public func previewAssetIds() async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM asset WHERE deleted = 0 AND source = 'preview' ORDER BY created DESC, id")
    }
  }

  public func previewAssetCount() async throws -> Int {
    try await database.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE deleted = 0 AND source = 'preview'") ?? 0
    }
  }

  /// `COUNT(*)` of what `pendingAssetIds` would return.
  public func pendingAssetCount(includingEmbedding: Bool, includingCloudOnly: Bool) async throws -> Int {
    let sql = Self.pendingCountSQL(includingEmbedding: includingEmbedding, includingCloudOnly: includingCloudOnly)
    return try await database.writer.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
  }

  /// Ids of live assets with work left, newest first (ties by id). With `includingEmbedding == false`
  /// only assets that still need Vision signals count (no embedder is attached). With
  /// `includingCloudOnly == false`, assets flagged `cloudOnly` are left out (a local-only pass can't
  /// fetch them). The Indexer snapshots this list once per pass and reads rows page by page.
  public func pendingAssetIds(includingEmbedding: Bool, includingCloudOnly: Bool) async throws -> [String] {
    let sql = Self.pendingIdsSQL(includingEmbedding: includingEmbedding, includingCloudOnly: includingCloudOnly)
    return try await database.writer.read { db in try String.fetchAll(db, sql: sql) }
  }

  /// Rows for `ids`, in the order given. Unknown ids are skipped.
  public func assets(ids: [String]) async throws -> [AssetRecord] {
    guard !ids.isEmpty else { return [] }
    let byId = try await database.writer.read { db in
      var found: [String: AssetRecord] = [:]
      for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
        let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
        for record in try AssetRecord.fetchAll(db, keys: batch) { found[record.id] = record }
      }
      return found
    }
    return ids.compactMap { byId[$0] }
  }

  /// The id, stored UTI and deleted flag of every row (or of `ids` only), for library sync: which ids are
  /// new, which UTI to keep for the byte estimate, and which live rows the library no longer reports.
  public func assetRefs(ids: [String]? = nil) async throws -> [AssetRef] {
    try await database.writer.read { db in
      let rows: [Row]
      if let ids {
        var collected: [Row] = []
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
          let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
          collected += try Row.fetchAll(
            db, sql: "SELECT id, uti, deleted FROM asset WHERE id IN (\(batch.map { _ in "?" }.joined(separator: ",")))",
            arguments: StatementArguments(batch))
        }
        rows = collected
      } else {
        rows = try Row.fetchAll(db, sql: "SELECT id, uti, deleted FROM asset")
      }
      return rows.map { AssetRef(id: $0["id"], uti: $0["uti"], deleted: $0["deleted"]) }
    }
  }

  /// Flags the assets as gone from the library. `deletedAt` keeps the first date (`upsertAssets` clears both
  /// when an asset comes back). Signals and the `embedded` flag stay; the Indexer purges vectors separately.
  public func markDeleted(_ ids: [String], at date: Date = Date()) async throws {
    let now = date.timeIntervalSince1970
    for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
      let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
      try await database.writer.write { db in
        _ = try AssetRecord.filter(keys: batch).updateAll(
          db, Column("deleted").set(to: true), Column("deletedAt").set(to: Column("deletedAt") ?? now))
      }
    }
  }

  /// Deleted rows still flagged `embedded`: their vectors are waiting to be purged.
  public func deletedEmbeddedIds() async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM asset WHERE deleted = 1 AND embedded = 1 ORDER BY id")
    }
  }

  /// The pixels changed (an edit, or a revert): clears `signalsDone`, `embedded`, `cloudOnly` and
  /// `attempts` so the asset is indexed again. The old signal values stay until new ones are committed.
  /// Returns how many rows changed. The caller removes the old vectors afterwards.
  @discardableResult
  public func resetForContentChange(ids: [String]) async throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try await database.writer.write { db in
      var changed = 0
      for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
        let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
        changed += try AssetRecord.filter(keys: batch).updateAll(
          db, Column("signalsDone").set(to: false), Column("embedded").set(to: false),
          Column("cloudOnly").set(to: false), Column("attempts").set(to: 0))
      }
      return changed
    }
  }

  /// Adds one failed load to each asset.
  public func recordFailedAttempts(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    try await database.writer.write { db in
      for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
        let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
        _ = try AssetRecord.filter(keys: batch).updateAll(db, Column("attempts") += 1)
      }
    }
  }

  /// Live assets excluded from pending because their loads kept failing.
  public func failedAssetCount() async throws -> Int {
    try await database.writer.read { db in
      try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM asset WHERE deleted = 0 AND attempts >= \(Schema.maxAttempts)
          AND (embedded = 0 OR signalsDone = 0)
        """) ?? 0
    }
  }

  /// Gives every failed asset another chance (for example from a "retry" button). Returns how many rows changed.
  @discardableResult
  public func resetFailures() async throws -> Int {
    try await database.writer.write { db in
      try AssetRecord.filter(Column("attempts") > 0).updateAll(db, Column("attempts").set(to: 0))
    }
  }

  /// Forgets that anything was embedded (the vector file is gone or stale). Keeps Vision signals.
  /// In the same transaction, drops every swipefile classifier (trained on the old vectors) and
  /// its swipe counter, so swipefiles start untrained against the new index.
  public func resetEmbedded() async throws {
    try await database.writer.write { db in
      _ = try AssetRecord.updateAll(db, Column("embedded").set(to: false))
      try db.execute(sql: "UPDATE swipefile SET classifier = NULL, classifierRevision = NULL, swipesSinceTrain = 0")
    }
  }

  /// Every live (not deleted) row, newest first (ties by id), feature prints included. For whole-library views
  /// (the cleanup summary, duplicate grouping); ranking reads its slimmer `rankingCandidates` instead.
  public func liveAssets() async throws -> [AssetRecord] {
    try await database.writer.read { db in
      try AssetRecord.fetchAll(db, sql: "SELECT * FROM asset WHERE deleted = 0 ORDER BY created DESC, id")
    }
  }

  /// `liveAssets()` without the feature prints (each about 3 KB; `featurePrint` is nil): enough for totals, sizes and
  /// squish candidates. Only duplicate grouping needs the prints.
  public func liveAssetsSlim() async throws -> [AssetRecord] {
    let columns = Self.allColumns.map { $0 == "featurePrint" ? "NULL AS featurePrint" : $0 }.joined(separator: ", ")
    return try await database.writer.read { db in
      try AssetRecord.fetchAll(db, sql: "SELECT \(columns) FROM asset WHERE deleted = 0 ORDER BY created DESC, id")
    }
  }

  /// Ids of live (not deleted) rows flagged `embedded`: the vectors the index should hold.
  public func liveEmbeddedIds() async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM asset WHERE embedded = 1 AND deleted = 0")
    }
  }

  /// Ids of every row flagged `embedded`.
  public func embeddedIds() async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM asset WHERE embedded = 1")
    }
  }

  /// Clears `embedded` for the given ids (the inverse of `markEmbedded`), all in one transaction. Returns how many rows changed.
  @discardableResult
  public func clearEmbedded(ids: [String]) async throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try await database.writer.write { db in
      var changed = 0
      for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
        let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
        changed += try AssetRecord.filter(keys: batch).filter(Column("embedded") == true)
          .updateAll(db, Column("embedded").set(to: false))
      }
      return changed
    }
  }

  // MARK: - Counters

  /// Adds `n` to the counter `key` in one write transaction and returns the new total.
  /// Throws `CounterError.limitExceeded`, changing nothing, if the total would pass `limit`.
  /// `n <= 0` just returns the current total.
  public func consumeCounter(key: String, n: Int, limit: Int) async throws -> Int {
    try await database.writer.write { db in
      let used = try QuotaRecord.fetchOne(db, key: key)?.value ?? 0
      guard n > 0 else { return used }
      guard n <= limit - used else { throw CounterError.limitExceeded }
      try QuotaRecord(key: key, value: used + n).save(db)
      return used + n
    }
  }

  /// Adds `min(n, limit - total)` to the counter `key` in one write transaction and returns how much it
  /// added. `n <= 0`, or a counter already at `limit`, adds nothing.
  public func consumeCounterUpTo(key: String, n: Int, limit: Int) async throws -> Int {
    try await database.writer.write { db in
      let used = try QuotaRecord.fetchOne(db, key: key)?.value ?? 0
      let spend = min(max(0, n), max(0, limit - used))
      guard spend > 0 else { return 0 }
      try QuotaRecord(key: key, value: used + spend).save(db)
      return spend
    }
  }

  public func counter(key: String) async throws -> Int {
    try await database.writer.read { db in try QuotaRecord.fetchOne(db, key: key)?.value ?? 0 }
  }

  // MARK: - Swipefiles

  public func save(_ swipefile: SwipefileRecord) async throws {
    try await database.writer.write { db in try swipefile.save(db) }
  }

  public func swipefile(id: String) async throws -> SwipefileRecord? {
    try await database.writer.read { db in try SwipefileRecord.fetchOne(db, key: id) }
  }

  public func swipefiles() async throws -> [SwipefileRecord] {
    try await database.writer.read { db in try SwipefileRecord.order(Column("created")).fetchAll(db) }
  }

  /// Deletes the swipefile and, by cascade, its decisions.
  public func deleteSwipefile(id: String) async throws {
    _ = try await database.writer.write { db in try SwipefileRecord.deleteOne(db, key: id) }
  }

  // MARK: - Decisions

  public func decisions(for swipefileId: String) async throws -> [DecisionRecord] {
    try await database.writer.read { db in
      try DecisionRecord.filter(Column("swipefileId") == swipefileId).order(Column("decidedAt")).fetchAll(db)
    }
  }

  /// Stores the decision, replacing any earlier one for the same (swipefile, asset).
  public func record(_ decision: DecisionRecord) async throws {
    try await database.writer.write { db in try decision.save(db) }
  }

  /// Takes back a decision that hasn't been applied yet. Applied decisions are history (the change happened), so they
  /// stay.
  public func undo(swipefileId: String, assetId: String) async throws {
    _ = try await database.writer.write { db in try Self.deleteUnapplied(db, swipefileId, assetId) }
  }

  /// Deletes the (swipefile, asset) decision only while `applied = 0`. Returns whether a row went.
  static func deleteUnapplied(_ db: Database, _ swipefileId: String, _ assetId: String) throws -> Bool {
    try DecisionRecord
      .filter(Column("swipefileId") == swipefileId && Column("assetId") == assetId && Column("applied") == false)
      .deleteAll(db) > 0
  }

  /// Decisions waiting to be applied: not applied yet and not "keep".
  public func queued(for swipefileId: String) async throws -> [DecisionRecord] {
    try await database.writer.read { db in
      try DecisionRecord
        .filter(Column("swipefileId") == swipefileId && Column("applied") == false && Column("verdict") != Verdict.keep.rawValue)
        .order(Column("decidedAt"), Column("assetId"))
        .fetchAll(db)
    }
  }

  /// After a library change succeeded: marks `decisions` applied and flags `deletedAssetIds` as gone
  /// (keeping any earlier `deletedAt`), all in one transaction, so the queue and the asset table never
  /// disagree about what happened. Decisions may span swipefiles. Unknown keys and ids are ignored.
  public func recordApplied(_ decisions: [DecisionKey], deletedAssetIds: [String], at date: Date = Date()) async throws {
    guard !decisions.isEmpty || !deletedAssetIds.isEmpty else { return }
    let now = date.timeIntervalSince1970
    try await database.writer.write { db in
      let statement = try db.cachedStatement(sql: "UPDATE decision SET applied = 1 WHERE swipefileId = ? AND assetId = ?")
      for key in decisions { try statement.execute(arguments: [key.swipefileId, key.assetId]) }
      for start in stride(from: 0, to: deletedAssetIds.count, by: Self.batchSize) {
        let batch = Array(deletedAssetIds[start..<min(start + Self.batchSize, deletedAssetIds.count)])
        _ = try AssetRecord.filter(keys: batch).updateAll(
          db, Column("deleted").set(to: true), Column("deletedAt").set(to: Column("deletedAt") ?? now))
      }
    }
  }

  public func markApplied(swipefileId: String, assetIds: [String]) async throws {
    for start in stride(from: 0, to: assetIds.count, by: Self.batchSize) {
      let batch = Array(assetIds[start..<min(start + Self.batchSize, assetIds.count)])
      try await database.writer.write { db in
        _ = try DecisionRecord
          .filter(Column("swipefileId") == swipefileId && batch.contains(Column("assetId")))
          .updateAll(db, Column("applied").set(to: true))
      }
    }
  }
}
