import Foundation
import Overview
import Store

/// A Mac analysis tool, not a unit test, and never part of the app: it reads a device database copied to this Mac and
/// writes identifier-free numbers (counts, sizes, distance percentiles) as JSON. Skipped unless both are set:
/// - `ROLL_EVIDENCE_DB`: the database file (read only: the tool copies it to a temporary folder, opens the copy with
///   the app's own `AppDatabase` and `Repositories`, and deletes the copy when done);
/// - `ROLL_EVIDENCE_OUT`: the folder the JSON goes to.
///
/// Never write an asset id, a date or anything else that identifies a photo into the output.
enum Evidence {
  static let env = ProcessInfo.processInfo.environment
  static var enabled: Bool { env["ROLL_EVIDENCE_DB"] != nil && env["ROLL_EVIDENCE_OUT"] != nil }

  /// Runs `body` over a temporary copy of the database, then deletes the copy.
  static func withCopy<T>(_ body: (Repositories) async throws -> T) async throws -> T {
    let source = URL(fileURLWithPath: env["ROLL_EVIDENCE_DB"]!)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-evidence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let copy = dir.appendingPathComponent("roll.sqlite")
    try FileManager.default.copyItem(at: source, to: copy)
    return try await body(Repositories(try AppDatabase.open(at: copy)))
  }

  static func write(_ name: String, _ object: [String: Any]) throws {
    let dir = URL(fileURLWithPath: env["ROLL_EVIDENCE_OUT"]!)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent(name))
  }

  /// Nearest-rank percentile (p in 0...100) of unsorted values; nil when empty.
  static func percentile<T: Comparable>(_ values: [T], _ p: Double) -> T? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }

  /// p50 / p90 / p99 / max of a sample, rounded to 3 decimals.
  static func spread(_ values: [Float]) -> [String: Any] {
    var out: [String: Any] = ["n": values.count]
    for (key, p) in [("p10", 10.0), ("p50", 50.0), ("p90", 90.0), ("p99", 99.0), ("max", 100.0)] {
      if let v = percentile(values, p) { out[key] = round3(Double(v)) }
    }
    return out
  }

  /// Decimal numbers, so the JSON shows `0.215`, not `0.21500000000000002`.
  static func round3(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", x)) }
  /// Decimal GB (1e9 bytes), 2 decimals, as Home's "about" sizes.
  static func gb(_ bytes: Int64) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", Double(bytes) / 1e9)) }

  /// Counts per bin: `[edges[k], edges[k+1])`, the last bin open-ended.
  static func histogram(_ values: [Float], edges: [Float]) -> [[String: Any]] {
    var counts = [Int](repeating: 0, count: edges.count)
    for v in values {
      let k = edges.lastIndex { v >= $0 } ?? 0
      counts[k] += 1
    }
    return edges.indices.map { k in
      ["from": round3(Double(edges[k])), "to": k + 1 < edges.count ? round3(Double(edges[k + 1])) : "inf",
       "count": counts[k]] as [String: Any]
    }
  }

  /// The Home numbers of one grouping: what `CleanupSummary` makes of `groups` over the whole live library.
  static func groupStats(_ groups: [[String]], live: [AssetRecord]) -> [String: Any] {
    let summary = CleanupSummary.make(records: live, groups: groups)
    var out: [String: Any] = [:]
    for (name, kind) in [("similar", DuplicateGroup.Kind.similarShots), ("duplicates", .duplicates)] {
      let gs = summary.groups(kind)
      let sizes = gs.map(\.members.count)
      let members = sizes.reduce(0, +)
      out[name] = [
        "groups": gs.count, "members": members, "extras": members - gs.count,
        "largest": sizes.max() ?? 0, "p50Size": percentile(sizes, 50) ?? 0, "p95Size": percentile(sizes, 95) ?? 0,
        "groupsOf10OrMore": sizes.filter { $0 >= 10 }.count,
        "pctOfLibrary": round3(Double(members) / Double(max(live.count, 1)) * 100),
        "extrasGB": gb(gs.reduce(0) { $0 + $1.reclaimableBytes }),
      ] as [String: Any]
    }
    return out
  }
}
