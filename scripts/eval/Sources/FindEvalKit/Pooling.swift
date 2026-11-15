import Foundation

/// One variant's answer to one query (`<pool dir>/<variant>/<slug>.json`). Private: holds ids.
public struct VariantRun: Codable, Sendable, Equatable {
  public var variant: String
  public var slug: String
  public var query: String
  /// The judging depth this run was pooled at.
  public var k: Int
  /// The answer best first (strong, then weaker, as the app lists them), cut at `max(k, VariantRun.keepAtLeast)`.
  public var top: [String]
  /// Full answer size: strong matches (on screen) and weaker ones (folded).
  public var strong: Int
  public var weaker: Int
  /// Ranking time on the Mac, query embedding excluded (the vectors are precomputed).
  public var elapsedMs: Double
  /// Variant-specific numbers (e.g. the best z), never ids.
  public var notes: [String: Double]?

  /// Recall is measured at 100, so a run keeps at least that many.
  public static let keepAtLeast = 100

  public init(variant: String, slug: String, query: String, k: Int, top: [String], strong: Int, weaker: Int,
              elapsedMs: Double, notes: [String: Double]? = nil) {
    self.variant = variant; self.slug = slug; self.query = query; self.k = k; self.top = top; self.strong = strong
    self.weaker = weaker; self.elapsedMs = elapsedMs; self.notes = notes
  }

  public var answer: Int { strong + weaker }
}

/// The union of every variant's top k for one query (`<pool dir>/pool/<slug>.json`): what gets judged. Private.
public struct PoolFile: Codable, Sendable, Equatable {
  public var slug: String
  public var query: String
  public var group: String
  public var expect: FindExpectation
  public var k: Int
  public var variants: [String]
  /// Interleaved by rank (every variant's 1st, then every 2nd, ...), each id once.
  public var ids: [String]

  public init(slug: String, query: String, group: String, expect: FindExpectation, k: Int, variants: [String],
              ids: [String]) {
    self.slug = slug; self.query = query; self.group = group; self.expect = expect; self.k = k
    self.variants = variants; self.ids = ids
  }
}

public enum Pooling {
  /// The union of `runs`' first `k` ids, interleaved by rank: rank 1 of each run (in the runs' order), then rank 2, ...
  /// Each id appears once, at its first appearance.
  public static func union(_ runs: [[String]], k: Int) -> [String] {
    var seen = Set<String>(), out: [String] = []
    let depth = runs.map { min($0.count, k) }.max() ?? 0
    for r in 0..<depth {
      for run in runs where r < min(run.count, k) && seen.insert(run[r]).inserted { out.append(run[r]) }
    }
    return out
  }

  /// Every pooled id over all queries, each once, sorted (for `thumb-request.txt`).
  public static func allIds(_ pools: [PoolFile]) -> [String] {
    Array(Set(pools.flatMap(\.ids))).sorted()
  }

  /// Variant folders in a pool root: subfolders other than `pool` holding at least one `.json` file.
  public static func variantDirectories(in root: URL) throws -> [String] {
    let fm = FileManager.default
    let names = try fm.contentsOfDirectory(atPath: root.path).sorted()
    return names.filter { name in
      var isDir: ObjCBool = false
      guard name != "pool", !name.hasPrefix("."),
            fm.fileExists(atPath: root.appending(path: name).path, isDirectory: &isDir), isDir.boolValue else { return false }
      return ((try? fm.contentsOfDirectory(atPath: root.appending(path: name).path)) ?? []).contains { $0.hasSuffix(".json") }
    }
  }
}
