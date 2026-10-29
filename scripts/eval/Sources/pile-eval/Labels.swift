import Foundation
import SQLite3

/// Reads label rules from a copy of Roll's database, read-only and immutable (the copy is never written; no
/// migrations run). Ids stay in memory: nothing here is written out.
final class LabelSource {
  private var db: OpaquePointer?

  struct Failure: Error, CustomStringConvertible { var description: String }

  init(path: String) throws {
    let uri = "file:\(path)?immutable=1"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
      throw Failure(description: "can't open the database read-only: \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  deinit { sqlite3_close(db) }

  /// Ids of live assets matching `condition` (a rule's SQL).
  func ids(where condition: String) throws -> Set<String> {
    try strings("SELECT id FROM asset WHERE deleted = 0 AND (\(condition))")
  }

  private func strings(_ sql: String) throws -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw Failure(description: "bad rule SQL: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(statement) }
    var out = Set<String>()
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
      if let text = sqlite3_column_text(statement, 0) { out.insert(String(cString: text)) }
    }
    return out
  }
}
