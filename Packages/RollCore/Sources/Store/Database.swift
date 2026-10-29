import Foundation
import GRDB

/// The app's SQLite database (GRDB), migrated on open.
public struct AppDatabase: Sendable {
  public let writer: any DatabaseWriter

  public init(_ writer: any DatabaseWriter) throws {
    self.writer = writer
    try Schema.migrator.migrate(writer)
  }

  public static func inMemory() throws -> AppDatabase {
    try AppDatabase(DatabaseQueue())
  }

  public static func open(at url: URL) throws -> AppDatabase {
    try AppDatabase(DatabasePool(path: url.path))
  }

  /// `<base>/Roll/roll.sqlite`; `base` defaults to Application Support. The folder is created if needed.
  public static func defaultURL(in base: URL? = nil) throws -> URL {
    try rollSupportDirectory(in: base).appendingPathComponent("roll.sqlite")
  }
}

/// `<base>/Roll`, created on demand. `base` defaults to the Application Support directory.
func rollSupportDirectory(in base: URL? = nil) throws -> URL {
  let root = try base ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
  let dir = root.appendingPathComponent("Roll", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}
