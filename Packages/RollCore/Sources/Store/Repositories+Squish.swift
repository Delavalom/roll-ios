import Foundation
import GRDB

public enum SquishJournalError: Error, Equatable, Sendable {
  /// `assetID` already has an open row (`SquishJournalRecord.State.open`): its copy may exist. Settle it first
  /// (finish, discard or reconcile); overwriting it would lose track of that copy.
  case openEntry(assetID: String, state: SquishJournalRecord.State)
}

/// The squish journal. Rows are keyed by the original's id: one squish per original at a time.
extension Repositories {
  /// Starts the journey for `assetID`, replacing a settled (committed or discarded) row. Throws
  /// `SquishJournalError.openEntry` if an open row exists. Call before asking the library for a copy.
  public func journalBegin(assetID: String, originalBytes: Int64, newBytes: Int64, at date: Date = Date()) async throws {
    try await database.writer.write { db in
      try Self.begin(db, assetID, originalBytes, newBytes, date)
    }
  }

  /// Synchronous twin of `journalBegin`, for code that cannot suspend.
  public func journalBeginSync(assetID: String, originalBytes: Int64, newBytes: Int64, at date: Date = Date()) throws {
    try database.writer.write { db in try Self.begin(db, assetID, originalBytes, newBytes, date) }
  }

  private static func begin(_ db: Database, _ id: String, _ original: Int64, _ new: Int64, _ date: Date) throws {
    if let existing = try SquishJournalRecord.fetchOne(db, key: id), existing.state.isOpen {
      throw SquishJournalError.openEntry(assetID: id, state: existing.state)
    }
    let t = date.timeIntervalSince1970
    try SquishJournalRecord(assetID: id, newAssetID: nil, state: .creating, createdAt: t, updatedAt: t,
                            originalBytes: original, newBytes: new).save(db)
  }

  /// Records the placeholder id of the copy being created. Synchronous because the caller reads the id inside the
  /// library's change block, before the copy exists.
  public func journalNoteNewAsset(assetID: String, newAssetID: String, at date: Date = Date()) throws {
    try database.writer.write { db in try Self.note(db, assetID, newAssetID, date) }
  }

  public func journalNoteNewAssetAsync(assetID: String, newAssetID: String, at date: Date = Date()) async throws {
    try await database.writer.write { db in try Self.note(db, assetID, newAssetID, date) }
  }

  private static func note(_ db: Database, _ id: String, _ newID: String, _ date: Date) throws {
    try db.execute(sql: "UPDATE squishJournal SET newAssetID = ?, state = 'created', updatedAt = ? WHERE assetID = ?",
                   arguments: [newID, date.timeIntervalSince1970, id])
  }

  /// Moves a row to `state`. A nil `payload` keeps the stored one.
  public func journalSetState(assetID: String, state: SquishJournalRecord.State, payload: Data?,
                              at date: Date = Date()) async throws {
    try await database.writer.write { db in
      try db.execute(sql: "UPDATE squishJournal SET state = ?, payload = COALESCE(?, payload), updatedAt = ? WHERE assetID = ?",
                     arguments: [state.rawValue, payload, date.timeIntervalSince1970, assetID])
    }
  }

  public func journalEntry(assetID: String) async throws -> SquishJournalRecord? {
    try await database.writer.read { db in try SquishJournalRecord.fetchOne(db, key: assetID) }
  }

  public func journalEntrySync(assetID: String) throws -> SquishJournalRecord? {
    try database.writer.read { db in try SquishJournalRecord.fetchOne(db, key: assetID) }
  }

  public func journalEntries(states: [SquishJournalRecord.State]) async throws -> [SquishJournalRecord] {
    let raw = states.map(\.rawValue)
    return try await database.writer.read { db in
      try SquishJournalRecord.filter(raw.contains(Column("state"))).order(Column("createdAt")).fetchAll(db)
    }
  }

  /// Ids of copies Roll created and still stands behind (everything except discarded). Squish skips them as
  /// candidates and Dedupe skips them so a copy is never offered for deletion next to its original.
  public func journaledCopyIDs() async throws -> Set<String> {
    try await database.writer.read { db in
      Set(try String.fetchAll(db, sql: "SELECT newAssetID FROM squishJournal WHERE newAssetID IS NOT NULL AND state != 'discarded'"))
    }
  }

  /// Originals with an open journal row: a copy may sit next to them. Squish doesn't offer them again until the row
  /// is settled (finished, discarded, or reconciled).
  public func openJournalAssetIDs() async throws -> Set<String> {
    let open = SquishJournalRecord.State.open.map(\.rawValue)
    return try await database.writer.read { db in
      Set(try String.fetchAll(db, SquishJournalRecord.select(Column("assetID")).filter(open.contains(Column("state")))))
    }
  }

  /// Drops finished rows (committed or discarded) last touched before `date`. Open rows are never pruned.
  public func pruneJournal(olderThan date: Date) async throws {
    try await database.writer.write { db in
      try db.execute(sql: "DELETE FROM squishJournal WHERE state IN ('committed', 'discarded') AND updatedAt < ?",
                     arguments: [date.timeIntervalSince1970])
    }
  }
}
