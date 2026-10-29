import Accelerate
import Store

/// A pool (a pile's live, embedded, filter-passing assets, or the whole library's) aligned with one
/// `VectorStore.dotAll` result: integers, no String lookups in the hot path. From `SwipefileEngine.poolScores`;
/// `candidates` scores piles with it, and typed search can reuse it.
///
/// Entries `0..<count` include the ones in `skipped` (decided in the pile, or excluded by the caller); `top` leaves
/// those out, so callers can score every entry with whole-array arithmetic.
public struct PoolScores: Sendable {
  /// Number of entries (skipped ones included).
  public var count: Int { source.count }
  /// Per entry: the preset's signal boost (0 without a preset).
  public let boosts: [Float]
  /// Every stored vector against every query: the whole index, not only the pool (e.g. for per-query statistics).
  public let dots: DotProducts
  /// Entries decided in the pile or excluded by the caller.
  public let skipped: Set<Int>
  /// How long each step took.
  public internal(set) var timings: SearchTimings

  /// Per entry: its row in `dots`, as a Float for `vDSP_vindex` (exact below 2^24 rows).
  let rows: [Float]
  /// Per entry: its index in `snapshot`.
  let source: [Int32]
  let snapshot: [RankingRow]

  public func id(_ k: Int) -> String { snapshot[Int(source[k])].asset.id }
  public func asset(_ k: Int) -> RankingAsset { snapshot[Int(source[k])].asset }
  /// Entry `k`'s dot product with query `j`.
  public func dot(_ k: Int, query j: Int) -> Float { dots.scores[j * dots.ids.count + Int(rows[k])] }

  /// Query `j`'s dots, one per entry.
  public func dots(query j: Int) -> [Float] {
    gather(dots.scores[(j * dots.ids.count)..<((j + 1) * dots.ids.count)])
  }

  /// `values[row]` for each entry (`values` has one value per row of `dots`).
  func gather(_ values: ArraySlice<Float>) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    guard count > 0 else { return out }
    values.withUnsafeBufferPointer { v in
      rows.withUnsafeBufferPointer { r in
        out.withUnsafeMutableBufferPointer { o in
          vDSP_vindex(v.baseAddress!, r.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(count))
        }
      }
    }
    return out
  }

  /// The untrained formula (`Scorer.combine`) for every entry, with whole-array arithmetic: the best of queries
  /// `0..<promptCount`, plus `Scorer.exampleWeight` x query `promptCount` when `hasCenter`, plus the boost.
  public func untrainedScores(promptCount: Int, hasCenter: Bool) -> [Float] {
    let n = dots.ids.count
    var best = [Float](repeating: 0, count: n)
    dots.scores.withUnsafeBufferPointer { s in
      best.withUnsafeMutableBufferPointer { b in
        guard let s = s.baseAddress, let b = b.baseAddress else { return }
        if promptCount > 0 { b.update(from: s, count: n) }
        for j in 1..<max(promptCount, 1) { vDSP_vmax(b, 1, s + j * n, 1, b, 1, vDSP_Length(n)) }
        if hasCenter {
          var w = Scorer.exampleWeight
          vDSP_vsma(s + promptCount * n, 1, &w, b, 1, b, 1, vDSP_Length(n))
        }
      }
    }
    var out = gather(best[...])
    vDSP_vadd(out, 1, boosts, 1, &out, 1, vDSP_Length(count))
    return out
  }

  /// Untrained piles on each query's own scale (`QueryScale`, the per-query idea from DigUp): per entry, the best
  /// over queries `0..<queryCount` of `z_j(dot_j + boost)`. The scale of each query comes from the whole index, not
  /// the pool, so a filtered pile is judged against the library. The mean example vector, when there is one, is
  /// simply another query here (not `Scorer.combine`'s additive half).
  public func untrainedZ(queryCount: Int) -> [Float] {
    var best = [Float](repeating: -.infinity, count: count)
    guard count > 0 else { return best }
    for j in 0..<queryCount {
      let scale = QueryScale(scores: Array(dots.scores(forQuery: j)))
      var x = dots(query: j)
      vDSP_vadd(x, 1, boosts, 1, &x, 1, vDSP_Length(count))
      var (a, b) = scale.linear
      vDSP_vsmsa(x, 1, &a, &b, &x, 1, vDSP_Length(count))
      vDSP_vmax(best, 1, x, 1, &best, 1, vDSP_Length(count))
    }
    return best
  }

  /// The best `limit` entries with `scores[k] >= minimum`, not skipped, best first; ties by id.
  public func top(_ scores: [Float], limit: Int, minimum: Float) -> [Int] {
    guard limit > 0 else { return [] }
    var best: [Int] = []
    best.reserveCapacity(limit + 1)
    func better(_ a: Int, _ b: Int) -> Bool { scores[a] != scores[b] ? scores[a] > scores[b] : id(a) < id(b) }
    scores.withUnsafeBufferPointer { s in
      for k in 0..<count {
        let v = s[k]
        guard v >= minimum else { continue }
        if best.count == limit, v < s[best[limit - 1]] { continue }
        if !skipped.isEmpty, skipped.contains(k) { continue }
        if best.count == limit, !better(k, best[limit - 1]) { continue }
        let at = best.firstIndex { better(k, $0) } ?? best.count
        best.insert(k, at: at)
        if best.count > limit { best.removeLast() }
      }
    }
    return best
  }
}
