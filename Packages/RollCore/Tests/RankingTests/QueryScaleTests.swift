import Ranking
import Store
import Testing

struct QueryScaleTests {
  /// 100 scores spread evenly over [0, 0.99] plus one far above them.
  private func spreadWithOneOutlier() -> [Float] {
    (0..<100).map { Float($0) / 100 } + [5]
  }

  @Test func zIsTheScoreInStandardDeviationsFromTheMean() {
    let scores: [Float] = (0..<40).map { $0 % 2 == 0 ? 1 : 3 }  // mean 2, sd 1
    let scale = QueryScale(scores: scores)
    #expect(!scale.isDegenerate)
    #expect(abs(scale.mean - 2) < 1e-5)
    #expect(abs(scale.deviation - 1) < 1e-5)
    #expect(abs(scale.z(4) - 2) < 1e-5)
    #expect(abs(scale.z(1) + 1) < 1e-5)
  }

  @Test func onlyTheOutlierPassesTheGate() {
    let scores = spreadWithOneOutlier()
    let scale = QueryScale(scores: scores)
    #expect(scores.filter { scale.passes($0) } == [5])
  }

  @Test func evenlySpreadScoresHaveNoOutlier() {
    // A uniform spread never reaches z = sqrt(3) ≈ 1.73: nothing stands out, so nothing passes.
    // The scores sit high (0.3 to 0.6), so the old fixed 0.2 floor would have passed every one of them.
    let scores = (0..<500).map { 0.3 + Float($0) / 500 * 0.3 }
    let scale = QueryScale(scores: scores)
    #expect(scores.allSatisfy { $0 >= QueryScale.rawFloor })
    #expect(scores.allSatisfy { !scale.passes($0) })
  }

  @Test func aTinyIndexFallsBackToTheRawFloor() {
    let scores: [Float] = [0.05, 0.1, 0.25, 0.9]
    let scale = QueryScale(scores: scores)
    #expect(scale.isDegenerate)
    #expect(scores.filter { scale.passes($0) } == [0.25, 0.9])
    // The fallback z puts the raw floor exactly on the gate.
    #expect(abs(scale.z(QueryScale.rawFloor) - QueryScale.zGate) < 1e-5)
  }

  @Test func equalScoresFallBackToTheRawFloor() {
    let low = QueryScale(scores: [Float](repeating: 0.1, count: 1_000))
    #expect(low.isDegenerate && !low.passes(0.1))
    let high = QueryScale(scores: [Float](repeating: 0.6, count: 1_000))
    #expect(high.isDegenerate && high.passes(0.6))
  }

  @Test func anEmptyIndexIsDegenerate() {
    let scale = QueryScale(scores: [])
    #expect(scale.isDegenerate && scale.count == 0)
    #expect(!scale.passes(0.1) && scale.passes(0.3))
  }

  @Test func aColumnOfDotProductsUsesThatQuerysScores() {
    // Two queries, row-major: query 0 has the outlier in row 0, query 1 has none.
    let rows = spreadWithOneOutlier().reversed().map { $0 }
    var flat: [Float] = []
    for (i, s) in rows.enumerated() { flat += [s, Float(i % 2)] }
    let scale0 = QueryScale(scores: flat, queryCount: 2, query: 0)
    #expect(scale0 == QueryScale(scores: rows))
    let scale1 = QueryScale(scores: flat, queryCount: 2, query: 1)
    #expect(abs(scale1.mean - 0.5) < 0.01)
  }

  /// For one query, z is a strictly increasing function of the cosine, so it never reorders hits.
  @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
  func zOrderEqualsCosineOrder(seed: UInt64) {
    var g = SeededRNG(seed: seed)
    let count = seed % 2 == 0 ? Int.random(in: 30...2_000, using: &g) : Int.random(in: 1..<30, using: &g)
    let scores = (0..<count).map { _ in Float.random(in: -0.2...0.9, using: &g) }
    let scale = QueryScale(scores: scores)
    let byCosine = scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
    let zs = scores.map(scale.z)
    // Walking the hits in cosine order, z never goes up (rounding may tie two neighbours, never swap them).
    let zAlongCosine = byCosine.map { zs[$0] }
    #expect(zip(zAlongCosine, zAlongCosine.dropFirst()).allSatisfy { $0 >= $1 })
    #expect(scale.isDegenerate == (count < QueryScale.minimumCount))
  }

  // MARK: - Several prompts

  /// Prompt 0 sits close to everything (cosines around 0.5), prompt 1 close to nothing (around 0).
  /// Row 0 is a little above prompt 0's crowd, row 1 stands far out for prompt 1.
  private func twoPromptDots() -> (scores: [Float], rows: Int) {
    var flat: [Float] = [0.56, 0.0, 0.0, 0.3]
    for i in 0..<200 {
      let spread = Float(i % 10) / 100  // 0 ... 0.09
      flat += [0.47 + spread, spread / 3]
    }
    return (flat, flat.count / 2)
  }

  @Test func severalPromptsTakeTheBestZ() {
    let (flat, rows) = twoPromptDots()
    let pile = PileScale(scores: flat, queryCount: 2)
    #expect(pile.scales.count == 2)
    let z0 = pile.z(row: 0), z1 = pile.z(row: 1)
    // Raw max would rank row 0 first (0.56 > 0.3); on each prompt's own scale row 1 stands out more.
    #expect(z1 > z0)
    #expect(pile.passes(row: 1) && !pile.passes(row: 0))
    for row in 0..<rows {
      let expected = max(pile.scales[0].z(flat[row * 2]), pile.scales[1].z(flat[row * 2 + 1]))
      #expect(abs(pile.z(row: row) - expected) < 1e-5)
    }
  }

  @Test func aBoostIsAddedOnTheCosineScale() {
    let (flat, _) = twoPromptDots()
    let pile = PileScale(scores: flat, queryCount: 2)
    let boosted = pile.z(row: 0, boost: 0.5)
    let expected = max(pile.scales[0].z(0.56 + 0.5), pile.scales[1].z(0 + 0.5))
    #expect(abs(boosted - expected) < 1e-5)
    #expect(pile.passes(row: 0, boost: 0.5))
  }

  /// `DotProducts` is query-major (one block per query); `PileScale(dots)` must read it as such and agree with the
  /// row-major form.
  @Test func pileScaleReadsQueryMajorDots() {
    let n = 40
    let q0 = (0..<n).map { Float($0) / Float(n) }
    let q1 = (0..<n).map { Float(n - $0) / Float(n) * 0.5 }
    let dots = DotProducts(ids: (0..<n).map { "a\($0)" }, queryCount: 2, scores: q0 + q1)
    var rowMajor: [Float] = []
    for r in 0..<n { rowMajor += [q0[r], q1[r]] }
    let fromDots = PileScale(dots), fromRows = PileScale(scores: rowMajor, queryCount: 2)
    #expect(fromDots.rowCount == n)
    for r in 0..<n { #expect(abs(fromDots.z(row: r) - fromRows.z(row: r)) < 1e-5) }
    #expect(QueryScale(dots, query: 1) == QueryScale(scores: q1))
  }

  // MARK: - Folding

  @Test func strongCountKeepsHitsWithinTheRatioOfTheTop() {
    #expect(Fold.strongCount([10, 5, 4.9, 1], ratio: 0.5) == 2)
    #expect(Fold.strongCount([10, 5, 4.9, 1]) == 3)  // default 0.4 (pile eval, 2026-10-29)
    #expect(Fold.strongCount([10, 5, 4.9, 3.9, 1]) == 3)
    #expect(Fold.strongCount([3]) == 1)
    #expect(Fold.strongCount([]) == 0)
    // A top that isn't positive gives no reference: nothing folds.
    #expect(Fold.strongCount([0, -1, -2]) == 3)
    #expect(Fold.defaultRatio == 0.4)
  }

  @Test func weakIsBelowTheRatioOfTheTop() {
    #expect(!Fold.isWeak(4, top: 10))
    #expect(Fold.isWeak(3.9, top: 10))
    #expect(Fold.isWeak(4.9, top: 10, ratio: 0.5))
    #expect(!Fold.isWeak(5, top: 10, ratio: 0.5))
    #expect(!Fold.isWeak(-3, top: 0))
    let sorted: [Float] = [8, 7, 4, 3.9, 0.1]
    #expect(sorted.filter { !Fold.isWeak($0, top: sorted[0]) }.count == Fold.strongCount(sorted))
  }
}
