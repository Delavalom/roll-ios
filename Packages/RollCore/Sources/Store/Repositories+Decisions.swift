import Foundation
import GRDB

/// Counters, swipefiles and decisions.
extension Repositories {
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
