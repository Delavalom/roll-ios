import GRDB

/// A key/value counter row (used by `FreeQuota`).
public struct QuotaRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "quota"

  public var key: String
  public var value: Int

  public init(key: String, value: Int) {
    self.key = key; self.value = value
  }
}
