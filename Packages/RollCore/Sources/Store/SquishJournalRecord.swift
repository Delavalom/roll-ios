import Foundation
import GRDB

/// One squish in flight, written before the library is changed so a crash or kill cannot lose track of a copy.
///
/// States: `creating` (about to ask the library for a copy; `newAssetID` is still nil), `created` (the library
/// returned an id), `verified` (the copy matched the original; `payload` holds what `commitDeletes` needs),
/// `committed` (the original was deleted), `discarded` (the copy was removed or never existed).
public struct SquishJournalRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "squishJournal"

  public enum State: String, Codable, Sendable, Equatable, DatabaseValueConvertible {
    case creating, created, verified, committed, discarded

    /// Not settled yet: a copy may exist (or be about to) next to the original.
    public static let open: [State] = [.creating, .created, .verified]
    public var isOpen: Bool { Self.open.contains(self) }
  }

  public var assetID: String
  public var newAssetID: String?
  public var state: State
  public var createdAt: Double
  public var updatedAt: Double
  public var originalBytes: Int64
  public var newBytes: Int64
  /// Opaque to the Store; Squish keeps its verified snapshot here.
  public var payload: Data?

  public init(assetID: String, newAssetID: String? = nil, state: State, createdAt: Double, updatedAt: Double,
              originalBytes: Int64, newBytes: Int64, payload: Data? = nil) {
    self.assetID = assetID; self.newAssetID = newAssetID; self.state = state; self.createdAt = createdAt
    self.updatedAt = updatedAt; self.originalBytes = originalBytes; self.newBytes = newBytes; self.payload = payload
  }
}
