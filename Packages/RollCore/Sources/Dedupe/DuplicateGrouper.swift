import Foundation
import Store

/// Number of differing bits between two perceptual hashes.
func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

private struct HashBucket: Hashable { var hash: UInt64; var mediaType: Int }
private struct GroupSummary { var ids: [String]; var bytes: Int64 }

/// Groups duplicate and near-duplicate shots. Pure: no I/O, no Vision. The feature-print decoding and
/// distance are injected so Dedupe does not depend on Signals.
///
/// **Star linkage, no chaining.** A group is its first shot (the anchor) plus later shots that are each close to the
/// anchor itself, within `window` seconds of it. A shot that only resembles another member is not pulled in, so a long
/// run of look-alikes (a slow pan, a scrolled chat) can't grow into one big group. The rule and its numbers on the
/// founder's library: docs/investigations/2026-10-29-similar-blurry.md.
public enum DuplicateGrouper {
  /// Seconds from a group's first shot (inclusive): later shots can join only within this span of it.
  public static let window: TimeInterval = 60
  /// Two feature prints closer than this (exclusive, squared distance) count as the same scene.
  public static let fpThreshold: Float = 0.30
  /// Largest hamming distance between perceptual hashes that still counts as "the same shot" in the window.
  public static let nearPhashDistance = 4
  /// A group's first shot examines at most this many unclaimed successors (in creation order), so a burst of
  /// thousands of shots with one timestamp costs O(n * maxNeighbors), not O(n^2). Above a real burst.
  public static let maxNeighbors = 64
  /// A global exact-hash bucket larger than this is not trusted on the hash alone (see `groups`).
  static let trustedBucketSize = 8

  /// Hashes of blank or saturated images (black frames, white walls) collide across unrelated photos.
  static func isUsableForGlobalMatch(_ hash: UInt64) -> Bool {
    let bits = hash.nonzeroBitCount
    return hash != 0 && hash != .max && bits > 4 && bits < 60
  }

  /// Convenience for callers whose feature prints are already comparable `Data`.
  public static func groups(
    records: [AssetRecord],
    window: TimeInterval = DuplicateGrouper.window,
    fpThreshold: Float = DuplicateGrouper.fpThreshold,
    excluding: Set<String> = [],
    distance: (Data, Data) -> Float
  ) -> [[String]] {
    groups(records: records, window: window, fpThreshold: fpThreshold, excluding: excluding, prepare: { $0 }, distance: distance)
  }

  /// - Parameters:
  ///   - window: seconds; see `DuplicateGrouper.window`.
  ///   - fpThreshold: see `DuplicateGrouper.fpThreshold`.
  ///   - prepare: decodes a stored feature print once. Called lazily, at most once per record, and never
  ///     for records that are not compared. Return `nil` if the data cannot be decoded; that record then
  ///     never links by feature print.
  ///   - excluding: ids that never take part, typically `Repositories.journaledCopyIDs()`: a squished copy made
  ///     by Roll looks like a duplicate of its original and must not be offered for deletion next to it.
  ///   - distance: distance between two prepared prints. Called at most `maxNeighbors` times per group anchor.
  /// - Returns: asset-id groups of size >= 2, each asset in at most one. Groups are ordered by total `estBytes`
  ///   descending, then by member count descending, then by first member id; members inside a group are ordered by
  ///   creation date, then id. Deleted records are ignored; only same-`mediaType` assets are linked by hash or print.
  ///
  /// Records are taken in creation order (undated last, then id), and a record claimed by a group never joins or
  /// starts another. Passes, in order:
  /// 1. Records sharing a non-empty `burstId` form a group, with no comparison.
  /// 2. Exact perceptual-hash matches anywhere in the library (saved twice, re-downloaded) over hashes that are usable
  ///    (not 0, not `.max`, popcount 5...59). A bucket of up to 8 same-hash records is a group outright. A bigger bucket
  ///    is probably a recurring screen or template: its records group by star linkage on prints alone (each unclaimed
  ///    one, in order, claims later ones whose print is under `fpThreshold` from its own, examining at most
  ///    `maxNeighbors`). Copies come out here, before the moment pass, so they show as Duplicates.
  /// 3. Moments: each dated, unclaimed record, in creation order, is an anchor; it claims later unclaimed records of its
  ///    media type created within `window` seconds of it whose hash is within `nearPhashDistance` bits of the anchor's
  ///    or whose print is under `fpThreshold` from the anchor's, examining at most `maxNeighbors` unclaimed successors.
  public static func groups<P>(
    records: [AssetRecord],
    window: TimeInterval = DuplicateGrouper.window,
    fpThreshold: Float = DuplicateGrouper.fpThreshold,
    excluding: Set<String> = [],
    prepare: (Data) -> P?,
    distance: (P, P) -> Float
  ) -> [[String]] {
    let live = records.filter { !$0.deleted && !excluding.contains($0.id) }
    // Total order: created ascending (undated last), then id. Makes every pass deterministic.
    let sorted = live.sorted { a, b in
      switch (a.created, b.created) {
      case let (x?, y?): return x != y ? x < y : a.id < b.id
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return a.id < b.id
      }
    }
    let n = sorted.count
    guard n >= 2 else { return [] }

    // Each print is decoded at most once. Outer nil: not tried yet. Inner nil: no print or undecodable.
    var cache = [P??](repeating: nil, count: n)
    func prepared(_ i: Int) -> P? {
      if let hit = cache[i] { return hit }
      let value = sorted[i].featurePrint.flatMap(prepare)
      cache[i] = .some(value)
      return value
    }
    func closePrints(_ i: Int, _ j: Int) -> Bool {
      guard sorted[i].featurePrint != nil, sorted[j].featurePrint != nil,
            let pi = prepared(i), let pj = prepared(j) else { return false }
      return distance(pi, pj) < fpThreshold
    }

    var free = Unclaimed(count: n)
    var groups: [[Int]] = []
    func add(_ members: [Int]) {
      for i in members { free.claim(i) }
      groups.append(members)
    }

    // Pass 1: bursts the library already grouped. Free.
    var bursts: [String: [Int]] = [:]
    for i in 0..<n {
      if let burst = sorted[i].burstId, !burst.isEmpty { bursts[burst, default: []].append(i) }
    }
    for members in bursts.values where members.count >= 2 { add(members) }

    // Pass 2: exact perceptual-hash matches anywhere in the library.
    var buckets: [HashBucket: [Int]] = [:]
    for i in 0..<n where !free.isClaimed(i) {
      guard let h = sorted[i].phash, isUsableForGlobalMatch(h) else { continue }
      buckets[HashBucket(hash: h, mediaType: sorted[i].mediaType), default: []].append(i)
    }
    for members in buckets.values.sorted(by: { $0[0] < $1[0] }) where members.count >= 2 {  // members ascend
      if members.count <= trustedBucketSize { add(members); continue }
      for (k, anchor) in members.enumerated() where !free.isClaimed(anchor) {
        var group = [anchor], examined = 0
        for j in members[(k + 1)...] where !free.isClaimed(j) {
          if examined == maxNeighbors { break }
          examined += 1
          if closePrints(anchor, j) { group.append(j) }
        }
        if group.count >= 2 { add(group) }
      }
    }

    // Pass 3: moments, around each group's first shot.
    let created = sorted.map { $0.created ?? .nan }
    var anchor = free.next(from: 0)
    while anchor < n, !created[anchor].isNaN {  // undated records sort last; they only take part in passes 1 and 2
      let a = sorted[anchor]
      var group = [anchor], examined = 0
      var j = free.next(from: anchor + 1)
      while j < n, created[j] - created[anchor] <= window, examined < maxNeighbors {
        examined += 1
        let b = sorted[j]
        if a.mediaType == b.mediaType {
          if let pa = a.phash, let pb = b.phash, hamming(pa, pb) <= nearPhashDistance {
            group.append(j)
          } else if closePrints(anchor, j) {
            group.append(j)
          }
        }
        j = free.next(from: j + 1)
      }
      if group.count >= 2 { add(group) }
      anchor = free.next(from: anchor + 1)
    }

    var result: [GroupSummary] = []
    for members in groups {
      let members = members.sorted()
      result.append(GroupSummary(ids: members.map { sorted[$0].id },
                                 bytes: members.reduce(0) { $0 + sorted[$1].estBytes }))
    }
    result.sort { a, b in
      if a.bytes != b.bytes { return a.bytes > b.bytes }
      if a.ids.count != b.ids.count { return a.ids.count > b.ids.count }
      return a.ids[0] < b.ids[0]
    }
    return result.map(\.ids)
  }
}

/// The unclaimed indices of `0..<count`, with `next(from:)` skipping claimed ones in near-constant time (a pointer
/// forest with path halving), so a pass over a run of claimed records costs nothing.
struct Unclaimed {
  private var parent: [Int]

  init(count: Int) { parent = Array(0...count) }  // `count` is the sentinel: "none left"

  func isClaimed(_ i: Int) -> Bool { parent[i] != i }

  mutating func claim(_ i: Int) { parent[i] = i + 1 }

  /// The smallest unclaimed index >= i, or `count` if none.
  mutating func next(from i: Int) -> Int {
    var x = min(i, parent.count - 1)
    while parent[x] != x {
      parent[x] = parent[parent[x]]
      x = parent[x]
    }
    return x
  }
}
