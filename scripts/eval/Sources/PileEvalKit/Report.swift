import Foundation

/// One query's results, identifier-free (counts and shares only).
public struct QueryReport: Codable, Sendable {
  public var name: String
  public var rule: String?
  public var expect: Expectation
  public var prompts: Int
  /// Assets the rule labels (among those with a vector); 0 for unlabelled and nonsense queries.
  public var positives: Int
  /// Cosine over every vector: mean, standard deviation, best.
  public var cosMean: Double
  public var cosSD: Double
  public var cosTop: Double
  /// The best z (best prompt per vector).
  public var zTop: Double
  /// Ranked by cosine, best prompt per vector (today's pile order); nil without a label.
  public var precisionAt20: Double?
  public var recallAt200: Double?
  public var cappedRecallAt200: Double?
  public var gates: [GateResult]
  /// At the composition gate (`Score.swift`): how many passing assets belong to each rule.
  public var composition: [String: Int]?

  public init(name: String, rule: String?, expect: Expectation, prompts: Int, positives: Int, cosMean: Double,
              cosSD: Double, cosTop: Double, zTop: Double, precisionAt20: Double?, recallAt200: Double?,
              cappedRecallAt200: Double?, gates: [GateResult]) {
    self.name = name; self.rule = rule; self.expect = expect; self.prompts = prompts; self.positives = positives
    self.cosMean = cosMean; self.cosSD = cosSD; self.cosTop = cosTop; self.zTop = zTop
    self.precisionAt20 = precisionAt20; self.recallAt200 = recallAt200; self.cappedRecallAt200 = cappedRecallAt200
    self.gates = gates
  }
}

/// Averages over a set of queries, one row per gate.
public struct GateSummary: Codable, Sendable {
  public var gate: String
  public var queries: Int
  /// Queries where nothing passed.
  public var empty: Int
  /// Mean precision over the queries where something passed.
  public var meanPrecision: Double?
  /// Mean recall over the queries with positives (nothing passing counts as 0).
  public var meanRecall: Double?
  public var medianPassing: Double
  public var fold: [FoldSummary]
}

public struct FoldSummary: Codable, Sendable {
  public var ratio: Double
  public var meanStrong: Double
  /// Mean share of the passing true matches that the fold hides.
  public var meanFoldedTrueShare: Double?
  /// Mean precision of what the fold hides.
  public var meanFoldedPrecision: Double?
  /// Mean precision of what stays on screen.
  public var meanStrongPrecision: Double?
}

public enum Summary {
  public static func byGate(_ reports: [QueryReport]) -> [GateSummary] {
    guard let gates = reports.first?.gates.map(\.gate) else { return [] }
    return gates.enumerated().map { g, name in
      let rows = reports.map { $0.gates[g] }
      let ratios = rows.first?.fold.map(\.ratio) ?? []
      let fold = ratios.enumerated().map { f, ratio in
        let folds = rows.map { $0.fold[f] }
        return FoldSummary(ratio: ratio, meanStrong: mean(folds.map { Double($0.strong) }) ?? 0,
                           meanFoldedTrueShare: mean(folds.compactMap(\.foldedTrueShare)),
                           meanFoldedPrecision: mean(folds.compactMap(\.foldedPrecision)),
                           meanStrongPrecision: mean(folds.compactMap(\.strongPrecision)))
      }
      return GateSummary(gate: name, queries: rows.count, empty: rows.filter { $0.passing == 0 }.count,
                         meanPrecision: mean(rows.compactMap(\.precision)), meanRecall: mean(rows.compactMap(\.recall)),
                         medianPassing: median(rows.map { Double($0.passing) }), fold: fold)
    }
  }

  static func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }

  static func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(), m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
  }
}
