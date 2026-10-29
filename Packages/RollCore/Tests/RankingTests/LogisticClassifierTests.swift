import Foundation
import Ranking
import Store
import Testing

struct LogisticClassifierTests {
  private func clusters(seed: UInt64) -> (pos: [[Float]], neg: [[Float]]) {
    var g = SeededRNG(seed: seed)
    let pos = (0..<20).map { _ in (0..<256).map { _ in Float.random(in: 0.2...1, using: &g) } }
    let neg = (0..<20).map { _ in (0..<256).map { _ in Float.random(in: -1 ... -0.2, using: &g) } }
    return (pos, neg)
  }

  @Test func separatesClusters() {
    let (pos, neg) = clusters(seed: 3)
    let m = LogisticClassifier.train(x: pos + neg, y: Array(repeating: 1, count: 20) + Array(repeating: 0, count: 20),
                                     weights: Array(repeating: 1, count: 40))
    let acc = (pos.map { m.prob($0) > 0.5 ? 1 : 0 }.reduce(0, +) + neg.map { m.prob($0) < 0.5 ? 1 : 0 }.reduce(0, +))
    #expect(Double(acc) / 40 > 0.95)
  }

  /// Overlapping unit-vector clusters, the shape real embeddings have: still mostly separable.
  @Test func separatesNoisyUnitVectorClusters() {
    var g = SeededRNG(seed: 11)
    let a = randomUnit(256, using: &g), b = randomUnit(256, using: &g)
    func near(_ c: [Float]) -> [Float] { unitVector(zip(c, randomUnit(256, using: &g)).map { $0 + 0.8 * $1 }) }
    let pos = (0..<12).map { _ in near(a) }, neg = (0..<12).map { _ in near(b) }
    let m = LogisticClassifier.train(x: pos + neg, y: Array(repeating: 1, count: 12) + Array(repeating: 0, count: 12),
                                     weights: Array(repeating: 1, count: 24))
    let testPos = (0..<50).map { _ in near(a) }, testNeg = (0..<50).map { _ in near(b) }
    let correct = testPos.filter { m.prob($0) > 0.5 }.count + testNeg.filter { m.prob($0) < 0.5 }.count
    #expect(Double(correct) / 100 > 0.9)
  }

  /// A heavier weight on one sample moves the decision toward it.
  @Test func weightsShiftTheFit() {
    let x: [[Float]] = [[1, 0], [1, 0]]
    let y: [Float] = [1, 0]
    let even = LogisticClassifier.train(x: x, y: y, weights: [1, 1])
    let skewed = LogisticClassifier.train(x: x, y: y, weights: [3, 1])
    #expect(abs(even.prob([1, 0]) - 0.5) < 1e-3)
    #expect(skewed.prob([1, 0]) > 0.7)
  }

  /// Each class totals 0.5; relative weights inside a class (the 2x prompt pseudo-positive) stay.
  @Test func classBalancedWeights() {
    // 2 real positives, 1 prompt pseudo-positive (weight 2), 8 negatives.
    let y: [Float] = [1, 1] + Array(repeating: 0, count: 8) + [1]
    let w = LogisticClassifier.classBalanced(y: y, weights: Array(repeating: 1, count: 10) + [2])
    #expect(w[0] == 0.125 && w[1] == 0.125 && w[10] == 0.25)
    #expect(w[2..<10].allSatisfy { $0 == 0.0625 })
    let positives = zip(y, w).filter { $0.0 == 1 }.map(\.1).reduce(0, +)
    let negatives = zip(y, w).filter { $0.0 == 0 }.map(\.1).reduce(0, +)
    #expect(positives == 0.5 && negatives == 0.5)

    #expect(LogisticClassifier.classBalanced(y: [1, 1], weights: [1, 3]) == [0.125, 0.375])  // one class only
    #expect(LogisticClassifier.classBalanced(y: [], weights: []).isEmpty)
    #expect(LogisticClassifier.classBalanced(y: [1, 0], weights: [0, 1]) == [0, 0.5])  // zero-total class stays 0
  }

  /// Overlapping clusters, 2 positives vs 18 negatives (a pile where the user mostly keeps): plain
  /// weights rate every fresh positive below 0.5, balanced weights rate every one above.
  @Test func balancingRescuesAMinorityClass() {
    var g = SeededRNG(seed: 21)
    let a = randomUnit(256, using: &g), b = randomUnit(256, using: &g)
    func near(_ c: [Float]) -> [Float] { unitVector(zip(c, randomUnit(256, using: &g)).map { $0 + 1.2 * $1 }) }
    let x = (0..<2).map { _ in near(a) } + (0..<18).map { _ in near(b) }
    let y: [Float] = [1, 1] + Array(repeating: 0, count: 18)
    let plain = LogisticClassifier.train(x: x, y: y, weights: Array(repeating: 1, count: 20))
    let balanced = LogisticClassifier.train(x: x, y: y,
                                            weights: LogisticClassifier.classBalanced(y: y, weights: Array(repeating: 1, count: 20)))
    let fresh = (0..<20).map { _ in near(a) }
    #expect(fresh.allSatisfy { plain.prob($0) < 0.5 })
    #expect(fresh.allSatisfy { balanced.prob($0) > 0.5 })
  }

  @Test func probIsTheSigmoidOfTheLogit() {
    let m = LogisticClassifier(w: [1, -2], b: 0.5)
    #expect(m.logit([2, 1]) == 0.5)
    #expect(abs(m.prob([2, 1]) - 1 / (1 + exp(-0.5))) < 1e-6)
    #expect(m.prob([1000, 0]) == 1)
    #expect(m.prob([-1000, 0]) == 0)
  }

  @Test func emptyOrDegenerateInputGivesAZeroModel() {
    let m = LogisticClassifier.train(x: [], y: [], weights: [])
    #expect(m.w.isEmpty && m.b == 0)
    let zeroWeights = LogisticClassifier.train(x: [[1, 2]], y: [1], weights: [0])
    #expect(zeroWeights.w == [0, 0] && zeroWeights.b == 0)
  }

  @Test func blobRoundTripsThroughTheSwipefileLayout() throws {
    let m = LogisticClassifier(w: (0..<256).map { Float($0) / 100 }, b: -0.25)
    let blob = m.blob
    #expect(blob.count == SwipefileRecord.classifierLength(dimensions: 256) * 4)
    let back = try #require(LogisticClassifier(blob: blob, dimensions: 256))
    #expect(back == m)
    #expect(LogisticClassifier(blob: blob, dimensions: 128) == nil)
  }

  /// A corrupt blob with NaN or infinity would make every probability NaN; it must not load.
  @Test(arguments: [Float.nan, .infinity, -.infinity])
  func nonFiniteBlobIsRejected(bad: Float) {
    var w = [Float](repeating: 0.1, count: 256)
    w[7] = bad
    #expect(LogisticClassifier(blob: LogisticClassifier(w: w, b: 0).blob, dimensions: 256) == nil)
    #expect(LogisticClassifier(blob: LogisticClassifier(w: [Float](repeating: 0.1, count: 256), b: bad).blob,
                               dimensions: 256) == nil)
  }

  /// 40 x 256, 200 iterations: under 50 ms in release (debug gets a sanity bound).
  @Test func trainsFast() {
    let (pos, neg) = clusters(seed: 5)
    let x = pos + neg, y = Array(repeating: Float(1), count: 20) + Array(repeating: 0, count: 20)
    let w = Array(repeating: Float(1), count: 40)
    _ = LogisticClassifier.train(x: x, y: y, weights: w)  // warm up
    var best = Duration.seconds(10)
    for _ in 0..<5 {
      let start = ContinuousClock.now
      _ = LogisticClassifier.train(x: x, y: y, weights: w)
      best = min(best, ContinuousClock.now - start)
    }
    print("RANKING-PERF train 40x256x200: \(best)")
    #if DEBUG
    #expect(best < .seconds(2))
    #else
    #expect(best < .milliseconds(50))
    #endif
  }
}
