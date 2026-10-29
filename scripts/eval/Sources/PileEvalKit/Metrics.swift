import Foundation

/// The per-query scale of the plan (lane L2, DigUp's `meaning`): z = (cos − mean) / sd over every vector in the index
/// for this query. One modality here (every Roll vector is an image embedding), so no per-modality centring.
public enum QueryScale {
  /// Below this deviation the query is flat and nothing stands out (z = 0 everywhere).
  public static let minDeviation: Float = 1e-6

  public static func z(_ scores: [Float]) -> [Float] {
    guard !scores.isEmpty else { return [] }
    let n = Double(scores.count)
    let mean = scores.reduce(0.0) { $0 + Double($1) } / n
    let variance = scores.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
    let sd = variance.squareRoot()
    guard sd >= Double(minDeviation) else { return [Float](repeating: 0, count: scores.count) }
    return scores.map { Float((Double($0) - mean) / sd) }
  }

  /// The best of several prompts per vector (`Scorer.combine`'s max over prompts). For z, pass each prompt's z.
  public static func bestPerVector(_ rows: [[Float]]) -> [Float] {
    guard var best = rows.first else { return [] }
    for row in rows.dropFirst() {
      precondition(row.count == best.count, "prompt rows differ in length")
      for i in best.indices where row[i] > best[i] { best[i] = row[i] }
    }
    return best
  }
}

public enum ScoreOrder {
  /// Vector positions, best score first; ties by position.
  public static func bestFirst(_ scores: [Float]) -> [Int] {
    scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
  }
}

public enum Metrics {
  /// True matches among the first `k`, divided by `k`.
  public static func precision(at k: Int, order: [Int], positives: Set<Int>) -> Double {
    guard k > 0 else { return 0 }
    return Double(order.prefix(k).filter(positives.contains).count) / Double(k)
  }

  /// True matches among the first `k`, divided by all true matches; nil without any.
  public static func recall(at k: Int, order: [Int], positives: Set<Int>) -> Double? {
    guard !positives.isEmpty else { return nil }
    return Double(order.prefix(k).filter(positives.contains).count) / Double(positives.count)
  }

  /// True matches among the first `k`, divided by min(all true matches, k): 1 when the first `k` are as full of
  /// matches as they can be.
  public static func cappedRecall(at k: Int, order: [Int], positives: Set<Int>) -> Double? {
    guard !positives.isEmpty, k > 0 else { return nil }
    return Double(order.prefix(k).filter(positives.contains).count) / Double(min(positives.count, k))
  }
}

/// One gate on one query: what passes, how much of it is right, and how the fold splits it.
public struct GateResult: Codable, Sendable, Equatable {
  public var gate: String
  public var threshold: Double
  public var passing: Int
  /// nil for unlabelled queries.
  public var truePassing: Int?
  /// truePassing / passing; nil when nothing passes or unlabelled.
  public var precision: Double?
  /// truePassing / positives; nil when unlabelled or without positives.
  public var recall: Double?
  public var fold: [FoldResult]

  public init(gate: String, threshold: Double, passing: Int, truePassing: Int?, precision: Double?, recall: Double?,
              fold: [FoldResult]) {
    self.gate = gate; self.threshold = threshold; self.passing = passing; self.truePassing = truePassing
    self.precision = precision; self.recall = recall; self.fold = fold
  }
}

/// The fold (DigUp's `strongCount`): of what passes, the strong part scores at least `ratio` × the top score; the
/// rest shows as "N weaker matches".
public struct FoldResult: Codable, Sendable, Equatable {
  public var ratio: Double
  public var strong: Int
  public var strongTrue: Int?
  public var folded: Int
  public var foldedTrue: Int?
  /// Of the true matches that passed the gate, the share folded away (lower is better).
  public var foldedTrueShare: Double?
  /// True matches among the folded ones (lower means the fold hides mostly wrong results).
  public var foldedPrecision: Double?
  /// True matches among the strong ones (what stays on screen).
  public var strongPrecision: Double?

  public init(ratio: Double, strong: Int, strongTrue: Int?, folded: Int, foldedTrue: Int?, foldedTrueShare: Double?,
              foldedPrecision: Double?, strongPrecision: Double?) {
    self.ratio = ratio; self.strong = strong; self.strongTrue = strongTrue; self.folded = folded
    self.foldedTrue = foldedTrue; self.foldedTrueShare = foldedTrueShare; self.foldedPrecision = foldedPrecision
    self.strongPrecision = strongPrecision
  }
}

public enum Gate {
  /// `scores` per vector (cosine for the fixed floor, z for the z gates); `positives` nil for unlabelled queries.
  public static func evaluate(name: String, scores: [Float], threshold: Float, positives: Set<Int>?,
                              foldRatios: [Double]) -> GateResult {
    let passing = scores.indices.filter { scores[$0] >= threshold }
    let truePassing = positives.map { p in passing.filter(p.contains).count }
    let top = passing.map { scores[$0] }.max()
    let fold = foldRatios.map { ratio -> FoldResult in
      let strong = top.map { t in passing.filter { Double(scores[$0]) >= Double(t) * ratio } } ?? []
      let strongSet = Set(strong)
      let folded = passing.filter { !strongSet.contains($0) }
      let strongTrue = positives.map { p in strong.filter(p.contains).count }
      let foldedTrue = positives.map { p in folded.filter(p.contains).count }
      return FoldResult(
        ratio: ratio, strong: strong.count, strongTrue: strongTrue, folded: folded.count, foldedTrue: foldedTrue,
        foldedTrueShare: truePassing.flatMap { $0 > 0 ? Double(foldedTrue ?? 0) / Double($0) : nil },
        foldedPrecision: folded.isEmpty ? nil : foldedTrue.map { Double($0) / Double(folded.count) },
        strongPrecision: strong.isEmpty ? nil : strongTrue.map { Double($0) / Double(strong.count) })
    }
    return GateResult(
      gate: name, threshold: Double(threshold), passing: passing.count, truePassing: truePassing,
      precision: passing.isEmpty ? nil : truePassing.map { Double($0) / Double(passing.count) },
      recall: positives.flatMap { p in p.isEmpty ? nil : Double(truePassing ?? 0) / Double(p.count) },
      fold: fold)
  }

  /// How many of what passes belong to each rule (rule → member positions).
  public static func composition(scores: [Float], threshold: Float, rules: [String: Set<Int>]) -> [String: Int] {
    let passing = scores.indices.filter { scores[$0] >= threshold }
    return rules.mapValues { members in passing.filter(members.contains).count }
  }
}
