import Foundation
import Testing
@testable import PileEvalKit

struct QueryScaleTests {
  @Test func zHasMeanZeroAndDeviationOne() {
    let z = QueryScale.z([1, 2, 3, 4, 5])
    #expect(abs(z.reduce(0, +)) < 1e-5)
    let sd = (z.map { $0 * $0 }.reduce(0, +) / Float(z.count)).squareRoot()
    #expect(abs(sd - 1) < 1e-5)
    #expect(z[4] > z[0])
  }

  @Test func aFlatQueryGivesNoOutliers() {
    #expect(QueryScale.z([0.3, 0.3, 0.3]).allSatisfy { $0 == 0 })
  }

  @Test func severalPromptsTakeTheBestPerVector() {
    #expect(QueryScale.bestPerVector([[0.1, 0.5, 0.2], [0.4, 0.1, 0.3]]) == [0.4, 0.5, 0.3])
    #expect(QueryScale.bestPerVector([[0.1, 0.2]]) == [0.1, 0.2])
  }
}

struct MetricsTests {
  @Test func orderIsBestFirstWithTiesByIndex() {
    #expect(ScoreOrder.bestFirst([0.2, 0.9, 0.2, 0.5]) == [1, 3, 0, 2])
  }

  @Test func precisionCountsTheTopK() {
    let order = [4, 3, 2, 1, 0]
    #expect(Metrics.precision(at: 2, order: order, positives: [4, 0]) == 0.5)
    // Fewer results than k: still divided by k, the list a person sees has holes.
    #expect(Metrics.precision(at: 10, order: [4], positives: [4]) == 0.1)
  }

  @Test func recallIsRawAndCapped() {
    let order = Array(0..<10)
    let positives: Set<Int> = [0, 1, 50, 60]
    #expect(Metrics.recall(at: 5, order: order, positives: positives) == 0.5)
    // Capped: found / min(positives, k), so a rule with thousands of members can still reach 1.
    #expect(Metrics.cappedRecall(at: 2, order: order, positives: positives) == 1)
    #expect(Metrics.recall(at: 5, order: order, positives: []) == nil)
  }
}

struct GateTests {
  private let scores: [Float] = [4.0, 3.0, 2.2, 1.9, 1.0, 0.0]
  private let positives: Set<Int> = [0, 2, 4]

  @Test func countsWhatPassesAndHowManyAreTrue() {
    let r = Gate.evaluate(name: "z>=2", scores: scores, threshold: 2, positives: positives, foldRatios: [])
    #expect(r.passing == 3)
    #expect(r.truePassing == 2)
    #expect(r.precision == 2.0 / 3.0)
    #expect(r.recall == 2.0 / 3.0)
  }

  @Test func nothingPassingMeansNoPrecision() {
    let r = Gate.evaluate(name: "z>=9", scores: scores, threshold: 9, positives: positives, foldRatios: [0.5])
    #expect(r.passing == 0)
    #expect(r.precision == nil)
    #expect(r.fold.first?.strong == 0)
  }

  @Test func unlabelledQueriesOnlyCount() {
    let r = Gate.evaluate(name: "z>=2", scores: scores, threshold: 2, positives: nil, foldRatios: [0.6])
    #expect(r.passing == 3)
    #expect(r.truePassing == nil && r.precision == nil && r.recall == nil)
    #expect(r.fold.first?.strong == 2)  // >= 0.6 × 4.0
    #expect(r.fold.first?.foldedTrue == nil)
  }

  /// Fold: of what passes, the strong part scores at least ratio × the top; the rest is "N weaker matches".
  @Test func foldSplitsStrongFromWeaker() throws {
    let r = Gate.evaluate(name: "z>=1", scores: scores, threshold: 1, positives: positives, foldRatios: [0.6])
    let f = try #require(r.fold.first)
    // Passing: 4.0, 3.0, 2.2, 1.9, 1.0. Strong: >= 2.4 → 4.0, 3.0. Folded: 2.2 (true), 1.9, 1.0 (true).
    #expect(f.strong == 2 && f.strongTrue == 1)
    #expect(f.folded == 3 && f.foldedTrue == 2)
    #expect(f.foldedTrueShare == 2.0 / 3.0)  // of the true matches that passed, the share folded away
    #expect(f.foldedPrecision == 2.0 / 3.0)
    #expect(f.strongPrecision == 0.5)
  }

  /// What passes, by rule: what kind of asset a query really returns (identifier-free counts).
  @Test func compositionCountsPassingMembersOfEachRule() {
    let c = Gate.composition(scores: scores, threshold: 2, rules: ["even": [0, 2, 4], "none": []])
    #expect(c == ["even": 2, "none": 0])
  }
}

struct SpecTests {
  @Test func decodesRulesAndQueries() throws {
    let json = """
      {"about": "x", "rules": {"shots": {"sql": "(subtypes & 4) != 0", "about": "s", "visible": true}},
       "queries": [{"name": "a", "text": "a screenshot", "rule": "shots", "expect": "matches"},
                   {"name": "b", "preset": "memes", "expect": "unlabelled"},
                   {"name": "c", "text": "qwzx", "expect": "nothing"}]}
      """
    let spec = try JSONDecoder().decode(PileSpec.self, from: Data(json.utf8))
    #expect(spec.rules["shots"]?.visible == true)
    #expect(spec.queries.map(\.expect) == [.matches, .unlabelled, .nothing])
    #expect(spec.queries[1].preset == "memes" && spec.queries[1].rule == nil)
    #expect(try spec.validated().queries.count == 3)
  }

  @Test func aQueryMustNameAKnownRuleAndOneSource() {
    let unknownRule = PileSpec(about: "", rules: [:], queries: [
      PileQuery(name: "a", text: "x", preset: nil, rule: "missing", expect: .matches),
    ])
    #expect(throws: PileSpec.Invalid.self) { try unknownRule.validated() }
    let twoSources = PileSpec(about: "", rules: [:], queries: [
      PileQuery(name: "a", text: "x", preset: "memes", rule: nil, expect: .unlabelled),
    ])
    #expect(throws: PileSpec.Invalid.self) { try twoSources.validated() }
  }
}

struct SummaryTests {
  @Test func averagesPerGateOverLabelledQueries() {
    func q(_ prec: Double?, _ rec: Double?, passing: Int) -> QueryReport {
      QueryReport(name: "q", rule: "r", expect: .matches, prompts: 1, positives: 10, cosMean: 0, cosSD: 0, cosTop: 0,
                  zTop: 0, precisionAt20: 0.5, recallAt200: 0.1, cappedRecallAt200: 0.2,
                  gates: [GateResult(gate: "g", threshold: 1, passing: passing, truePassing: nil, precision: prec,
                                     recall: rec, fold: [])])
    }
    let rows = Summary.byGate([q(1, 0.2, passing: 4), q(nil, 0, passing: 0)])
    #expect(rows.count == 1)
    #expect(rows[0].gate == "g")
    #expect(rows[0].queries == 2)
    #expect(rows[0].empty == 1)
    #expect(rows[0].meanPrecision == 1)  // over queries where something passed
    #expect(rows[0].meanRecall == 0.1)  // over all labelled queries (nothing found = recall 0)
    #expect(rows[0].medianPassing == 2)
  }

  @Test func averagesTheFoldsStrongPrecision() {
    func q(strong: Int, strongTrue: Int) -> QueryReport {
      let fold = FoldResult(ratio: 0.5, strong: strong, strongTrue: strongTrue, folded: 0, foldedTrue: 0,
                            foldedTrueShare: nil, foldedPrecision: nil,
                            strongPrecision: strong > 0 ? Double(strongTrue) / Double(strong) : nil)
      return QueryReport(name: "q", rule: "r", expect: .matches, prompts: 1, positives: 10, cosMean: 0, cosSD: 0,
                         cosTop: 0, zTop: 0, precisionAt20: nil, recallAt200: nil, cappedRecallAt200: nil,
                         gates: [GateResult(gate: "g", threshold: 1, passing: strong, truePassing: strongTrue,
                                            precision: nil, recall: nil, fold: [fold])])
    }
    let rows = Summary.byGate([q(strong: 4, strongTrue: 4), q(strong: 2, strongTrue: 0), q(strong: 0, strongTrue: 0)])
    #expect(rows[0].fold[0].meanStrongPrecision == 0.5)
  }
}
