import Foundation
import Overview
import Signals
import Store

/// Tool-local versions of the grouping rules for the evidence tool (`SimilarEvidenceTests`), over records in
/// `DuplicateGrouper`'s order with every print decoded once by `FeaturePrints.decode` (the app's decoder and distance).
/// `unionFind` reproduces the rule shipped before 2026-10-29 so its numbers stay measurable after the change; `anchor`
/// is the candidate rule. The tool checks each against `DuplicateGrouper` when the code implements it.
struct GroupingLab {
  let records: [AssetRecord]
  let prints: [FeaturePrints.Print?]
  let created: [Double]

  init(_ input: [AssetRecord]) {
    records = input.sorted { a, b in
      switch (a.created, b.created) {
      case let (x?, y?): return x != y ? x < y : a.id < b.id
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return a.id < b.id
      }
    }
    prints = records.map { $0.featurePrint.flatMap(FeaturePrints.decode) }
    created = records.map { $0.created ?? .nan }
  }

  var count: Int { records.count }

  func distance(_ i: Int, _ j: Int) -> Float? {
    guard let a = prints[i], let b = prints[j] else { return nil }
    return a.distance(to: b)
  }

  func nearHash(_ i: Int, _ j: Int) -> Bool {
    guard let a = records[i].phash, let b = records[j].phash else { return false }
    return (a ^ b).nonzeroBitCount <= 4
  }

  /// `DuplicateGrouper.isUsableForGlobalMatch`.
  static func usable(_ h: UInt64) -> Bool { h != 0 && h != .max && h.nonzeroBitCount > 4 && h.nonzeroBitCount < 60 }

  /// Exact-hash buckets of 2 or more (same hash and media type), members ascending.
  func exactBuckets(skip: [Bool]? = nil) -> [[Int]] {
    var buckets: [[UInt64]: [Int]] = [:]
    for i in 0..<count where skip?[i] != true {
      guard let h = records[i].phash, Self.usable(h) else { continue }
      buckets[[h, UInt64(records[i].mediaType)], default: []].append(i)
    }
    return buckets.values.filter { $0.count >= 2 }.sorted { $0[0] < $1[0] }
  }

  /// Same-media pairs the old window pass compared: within `window` seconds and `neighbors` positions.
  func windowPairs(window: Double = 120, neighbors: Int = 24) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    for i in 0..<count {
      if created[i].isNaN { break }
      var j = i + 1
      while j <= min(count - 1, i + neighbors), created[j] - created[i] <= window {
        if records[i].mediaType == records[j].mediaType { out.append((i, j)) }
        j += 1
      }
    }
    return out
  }

  /// The shipped rule up to 2026-10-29: bursts, window links (near hash or print under `threshold`) and the guarded
  /// exact-hash pass, merged transitively by union-find.
  func unionFind(threshold: Float) -> [[Int]] {
    var parent = Array(0..<count)
    func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
    func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
    var firstInBurst: [String: Int] = [:]
    for i in 0..<count {
      guard let burst = records[i].burstId, !burst.isEmpty else { continue }
      if let j = firstInBurst[burst] { union(j, i) } else { firstInBurst[burst] = i }
    }
    for (i, j) in windowPairs() where nearHash(i, j) || (distance(i, j).map { $0 < threshold } ?? false) { union(i, j) }
    for members in exactBuckets() {
      if members.count <= 8 { for k in members.dropFirst() { union(members[0], k) }; continue }
      for (k, i) in members.enumerated() {
        for j in members[(k + 1)..<min(members.count, k + 25)] where (distance(i, j).map { $0 < threshold } ?? false) {
          union(i, j)
        }
      }
    }
    var components: [Int: [Int]] = [:]
    for i in 0..<count { components[find(i), default: []].append(i) }
    return components.values.filter { $0.count >= 2 }.sorted { $0[0] < $1[0] }
  }

  struct AnchorRule: CustomStringConvertible {
    var threshold: Float
    /// Seconds from the anchor (inclusive).
    var span: Double
    /// Unclaimed successors an anchor examines at most.
    var cap: Int
    /// The exact-hash pass claims records before the window pass (else after it, over what's left).
    var exactFirst = true
    var description: String { "anchor t=\(threshold) span=\(Int(span))s cap=\(cap)\(exactFirst ? "" : " exactLast")" }
  }

  /// Star linkage: bursts first, then the exact-hash pass (a bucket of up to 8 outright, a bigger one by anchor and
  /// print), then the time-ordered window pass. Each unclaimed record is an anchor; it claims later unclaimed records of
  /// its media type within `span` whose hash is within 4 bits of the anchor's or whose print is under `threshold` from
  /// the anchor's. Claimed records never anchor or join again: no chaining.
  func anchor(_ rule: AnchorRule) -> (groups: [[Int]], capHits: Int, comparisons: Int, orphans: Int) {
    var claimed = [Bool](repeating: false, count: count)
    var groups: [[Int]] = []
    var capHits = 0, comparisons = 0
    func close(_ i: Int, _ j: Int) -> Bool {
      comparisons += 1
      return distance(i, j).map { $0 < rule.threshold } ?? false
    }
    var bursts: [String: [Int]] = [:]
    for i in 0..<count { if let b = records[i].burstId, !b.isEmpty { bursts[b, default: []].append(i) } }
    for members in bursts.values.sorted(by: { $0[0] < $1[0] }) where members.count >= 2 {
      groups.append(members); members.forEach { claimed[$0] = true }
    }
    func exactPass() {
      for members in exactBuckets(skip: claimed) {
        if members.count <= 8 { groups.append(members); members.forEach { claimed[$0] = true }; continue }
        for (k, a) in members.enumerated() where !claimed[a] {
          var group = [a], examined = 0
          for j in members[(k + 1)...] where !claimed[j] {
            if examined == rule.cap { break }
            examined += 1
            if close(a, j) { group.append(j); claimed[j] = true }
          }
          if group.count >= 2 { claimed[a] = true; groups.append(group) }
        }
      }
    }
    if rule.exactFirst { exactPass() }
    for a in 0..<count where !claimed[a] {
      if created[a].isNaN { break }
      var group = [a], examined = 0, j = a + 1
      while j < count, created[j] - created[a] <= rule.span {
        if !claimed[j] {
          if examined == rule.cap { capHits += 1; break }
          examined += 1
          if records[j].mediaType == records[a].mediaType, nearHash(a, j) || close(a, j) {
            group.append(j); claimed[j] = true
          }
        }
        j += 1
      }
      if group.count >= 2 { claimed[a] = true; groups.append(group) }
    }
    if !rule.exactFirst { exactPass() }
    // Exact copies (a trusted bucket of up to 8) left in no group because a bucket-mate was already claimed.
    let orphans = exactBuckets().filter { $0.count <= 8 }.reduce(0) { $0 + $1.filter { !claimed[$0] }.count }
    return (groups.map { $0.sorted() }, capHits, comparisons, orphans)
  }

  func ids(_ groups: [[Int]]) -> [[String]] { groups.map { $0.sorted().map { records[$0].id } } }

  /// Identifier-free shape of a grouping: distances from each group's first shot, time spans, widest pair.
  func sanity(_ groups: [[Int]]) -> [String: Any] {
    var anchorD: [Float] = [], maxPair: [Float] = [], spans: [Float] = []
    for g in groups {
      let g = g.sorted()
      for j in g.dropFirst() { if let d = distance(g[0], j) { anchorD.append(d) } }
      if let last = g.last, !created[last].isNaN, !created[g[0]].isNaN { spans.append(Float(created[last] - created[g[0]])) }
      guard g.count <= 60 else { continue }
      var widest: Float = 0
      for x in 0..<g.count { for y in (x + 1)..<g.count { if let d = distance(g[x], g[y]) { widest = max(widest, d) } } }
      maxPair.append(widest)
    }
    return ["anchorToMemberDistance": Evidence.spread(anchorD), "widestPairDistance(groups<=60)": Evidence.spread(maxPair),
            "groupSpanSeconds": Evidence.spread(spans)]
  }

  /// Home's numbers for `groups` (`Evidence.groupStats`), plus per kind: the shape (`sanity`), the share of members
  /// that are screenshots, the share in groups whose members all share one timestamp (saved in one go, typically from
  /// a messaging app), and for duplicates how many groups are exact-hash copies.
  func describe(_ groups: [[Int]], live: [AssetRecord]) -> [String: Any] {
    var out = Evidence.groupStats(ids(groups), live: live)
    let index = Dictionary(uniqueKeysWithValues: records.indices.map { (records[$0].id, $0) })
    let summary = CleanupSummary.make(records: live, groups: ids(groups))
    for (name, kind) in [("similar", DuplicateGroup.Kind.similarShots), ("duplicates", .duplicates)] {
      let gs = summary.groups(kind).map { $0.members.compactMap { index[$0] } }
      let members = gs.flatMap { $0 }
      var row = out[name] as! [String: Any]
      row["sanity"] = sanity(gs)
      let screenshots = members.filter { records[$0].subtypes & 4 != 0 }.count
      row["pctMembersScreenshots"] = Evidence.round3(Double(screenshots) / Double(max(members.count, 1)) * 100)
      let oneInstant = gs.filter { g in g.allSatisfy { created[$0] == created[g[0]] } }.reduce(0) { $0 + $1.count }
      row["pctMembersInOneTimestampGroups"] = Evidence.round3(Double(oneInstant) / Double(max(members.count, 1)) * 100)
      row["exactHashGroups"] = gs.filter { g in g.allSatisfy { records[$0].phash == records[g[0]].phash } }.count
      out[name] = row
    }
    return out
  }
}
