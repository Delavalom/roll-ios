import GRDB

public enum Verdict: String, Codable, Sendable, DatabaseValueConvertible {
  /// Do the swipefile's action (delete, squish, ...).
  case action
  case keep
  /// Add to an album.
  case album
}

public struct DecisionRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "decision"

  public var swipefileId: String
  public var assetId: String
  public var verdict: Verdict
  public var decidedAt: Double
  public var applied: Bool

  public init(swipefileId: String, assetId: String, verdict: Verdict, decidedAt: Double, applied: Bool = false) {
    self.swipefileId = swipefileId; self.assetId = assetId; self.verdict = verdict
    self.decidedAt = decidedAt; self.applied = applied
  }
}

/// Identifies one decision row (its primary key).
public struct DecisionKey: Hashable, Sendable {
  public var swipefileId: String
  public var assetId: String

  public init(swipefileId: String, assetId: String) {
    self.swipefileId = swipefileId; self.assetId = assetId
  }
}

extension DecisionRecord {
  public var key: DecisionKey { DecisionKey(swipefileId: swipefileId, assetId: assetId) }
}
