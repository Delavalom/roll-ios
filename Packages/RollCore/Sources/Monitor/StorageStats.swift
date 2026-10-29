import Foundation

/// Volume capacity at one moment.
public struct StorageSnapshot: Sendable, Equatable {
  public var total: Int64
  /// Space the system would make available for important data (includes purgeable space).
  public var available: Int64

  public init(total: Int64, available: Int64) { self.total = total; self.available = available }

  /// `(total - available) / total`, clamped to 0...1.
  public var usedFraction: Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(total - available) / Double(total)))
  }
}

/// Capacity of the volume holding the app's home directory. Storage changes slowly and is read on demand
/// (when the Monitor screen appears or refreshes); `DeviceSampler` does not sample it every second.
public enum StorageStats {
  /// The volume did not report a value the snapshot needs.
  public struct MissingValue: Error, Sendable, Equatable {
    public let key: URLResourceKey
  }

  public static func snapshot() throws -> StorageSnapshot {
    let values = try URL(fileURLWithPath: NSHomeDirectory())
      .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
    return try snapshot(total: values.volumeTotalCapacity,
                        available: values.volumeAvailableCapacityForImportantUsage)
  }

  /// Split out so the missing-value paths can be tested (`URLResourceValues` is read-only).
  static func snapshot(total: Int?, available: Int64?) throws -> StorageSnapshot {
    guard let total else { throw MissingValue(key: .volumeTotalCapacityKey) }
    guard let available else { throw MissingValue(key: .volumeAvailableCapacityForImportantUsageKey) }
    return StorageSnapshot(total: Int64(total), available: available)
  }
}
