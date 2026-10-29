#if DEBUG
import Foundation
import GRDB

/// What `AppDatabase.resetForUITests(at:)` did.
public enum UITestResetOutcome: Equatable, Sendable {
  /// No unfinished squish: the whole `Roll` folder (database and vector index) is gone, as after a fresh install.
  case removedEverything
  /// `openSquishes` journal rows were still open, so their copies may sit next to their originals. The journal was
  /// kept whole (settled rows too, so `journaledCopyIDs` still covers every copy) and everything else was emptied.
  case keptSquishJournal(openSquishes: Int)
}

extension AppDatabase {
  /// DEBUG-only `-UITestResetState`: a fresh install's state for the database at `url` (`defaultURL(in:)`) and the
  /// files next to it (the vector index), except that it never loses an unfinished squish. With open journal rows,
  /// deleting the journal would drop the recovery banner and let the copy show up next to its original in Squish and
  /// Duplicates (review 2026-10-24). Call before anything opens the database. A database that can't be opened throws
  /// and is left alone: it may hold an open journal.
  public static func resetForUITests(at url: URL) throws -> UITestResetOutcome {
    let files = FileManager.default
    let folder = url.deletingLastPathComponent()
    guard files.fileExists(atPath: url.path) else {
      if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
      return .removedEverything
    }
    let database = try open(at: url)
    let open = try database.writer.write { db -> Int in
      let open = try SquishJournalRecord.filter(SquishJournalRecord.State.open.map(\.rawValue).contains(Column("state")))
        .fetchCount(db)
      guard open > 0 else { return 0 }
      // The keyword index (v10) and its shadow tables follow `assetText` through triggers; SQLite refuses direct writes.
      let tables = try String.fetchAll(db, sql: """
        SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        AND name NOT IN ('squishJournal', 'grdb_migrations') AND name NOT LIKE 'assetTextFts%'
        """)
      for table in tables { try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)") }
      return open
    }
    try database.writer.close()
    guard open > 0 else {
      try files.removeItem(at: folder)
      return .removedEverything
    }
    // Everything but the database itself (the vector index: its vectors belong to the rows just emptied).
    let name = url.lastPathComponent
    let keep: Set<String> = [name, "\(name)-wal", "\(name)-shm"]
    for item in try files.contentsOfDirectory(atPath: folder.path) where !keep.contains(item) {
      try files.removeItem(at: folder.appendingPathComponent(item))
    }
    return .keptSquishJournal(openSquishes: open)
  }
}
#endif
