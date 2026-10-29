import Accelerate
import Foundation
import Store

/// L2-regularized logistic regression over embedding vectors: `prob(v) = sigmoid(w·v + b)`.
///
/// Trained per swipefile once it has enough swipes (see `SwipefileEngine`), and persisted in
/// `SwipefileRecord.classifier` with the `dimensions + 1` float layout (weights, then bias).
public struct LogisticClassifier: Sendable, Equatable {
  public var w: [Float]
  public var b: Float

  public init(w: [Float], b: Float) {
    self.w = w
    self.b = b
  }

  /// Decodes a persisted classifier; nil unless `blob` holds exactly `dimensions + 1` floats, all
  /// finite (a NaN or infinite weight would make every probability NaN).
  public init?(blob: Data, dimensions: Int) {
    guard let values = SwipefileRecord.decodeClassifier(blob, dimensions: dimensions),
          values.allSatisfy(\.isFinite) else { return nil }
    self.init(w: Array(values.dropLast()), b: values[values.count - 1])
  }

  /// The `SwipefileRecord.classifier` encoding.
  public var blob: Data { SwipefileRecord.encodeClassifier(w + [b]) }

  /// `w·x + b`. `x` must have `w.count` elements.
  public func logit(_ x: [Float]) -> Float {
    precondition(x.count == w.count, "vector has \(x.count) dimensions, classifier has \(w.count)")
    var dot: Float = 0
    vDSP_dotpr(w, 1, x, 1, &dot, vDSP_Length(w.count))
    return dot + b
  }

  public func prob(_ x: [Float]) -> Float { Self.sigmoid(logit(x)) }

  public static func sigmoid(_ z: Float) -> Float { 1 / (1 + exp(-z)) }

  /// Rescales `weights` so each class present in `y` totals 0.5, keeping the ratios inside a class
  /// (a weight-2 prompt pseudo-positive still counts twice a swiped positive). Without this, a
  /// pile where most swipes are "keep" trains a classifier that rates every asset below 0.5.
  /// A class whose weights sum to 0 stays 0.
  public static func classBalanced(y: [Float], weights: [Float]) -> [Float] {
    precondition(y.count == weights.count, "y and weights must have the same count")
    var positive: Float = 0, negative: Float = 0
    for (label, w) in zip(y, weights) {
      if label > 0.5 { positive += w } else { negative += w }
    }
    return zip(y, weights).map { label, w in
      let total = label > 0.5 ? positive : negative
      return total > 0 ? 0.5 * w / total : 0
    }
  }

  /// Full-batch gradient descent on the weighted mean log loss plus `l2/2 · |w|²` (the bias is
  /// not regularized). Sample weights are normalized to sum to 1, so `lr` doesn't depend on `n`.
  ///
  /// - Parameters:
  ///   - x: `n` rows of equal length `d`.
  ///   - y: labels in {0, 1}.
  ///   - weights: per-sample weights (>= 0).
  /// - Returns: a zero model of width `d` (or 0 when `x` is empty) if the weights sum to 0.
  public static func train(x: [[Float]], y: [Float], weights: [Float], l2: Float = 1e-2,
                           iters: Int = 200, lr: Float = 0.5) -> LogisticClassifier {
    let n = x.count
    let d = x.first?.count ?? 0
    precondition(y.count == n && weights.count == n, "x, y and weights must have the same count")
    precondition(x.allSatisfy { $0.count == d }, "rows must have equal length")
    let total = weights.reduce(0, +)
    guard n > 0, d > 0, total > 0 else { return LogisticClassifier(w: [Float](repeating: 0, count: d), b: 0) }

    let s = weights.map { $0 / total }
    let flat = x.flatMap { $0 }                       // n x d, row-major
    var flatT = [Float](repeating: 0, count: n * d)   // d x n
    vDSP_mtrans(flat, 1, &flatT, 1, vDSP_Length(d), vDSP_Length(n))

    var w = [Float](repeating: 0, count: d)
    var b: Float = 0
    var z = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    var grad = [Float](repeating: 0, count: d)
    var count = Int32(n)

    for _ in 0..<iters {
      // z = X w + b
      vDSP_mmul(flat, 1, w, 1, &z, 1, vDSP_Length(n), 1, vDSP_Length(d))
      var bias = b
      vDSP_vsadd(z, 1, &bias, &z, 1, vDSP_Length(n))
      // p = 1 / (1 + exp(-z)), computed in place in z
      var minusOne: Float = -1
      vDSP_vsmul(z, 1, &minusOne, &z, 1, vDSP_Length(n))
      vvexpf(&z, z, &count)
      var one: Float = 1
      vDSP_vsadd(z, 1, &one, &z, 1, vDSP_Length(n))
      vvrecf(&z, z, &count)
      // r = s * (p - y)
      vDSP_vsub(y, 1, z, 1, &r, 1, vDSP_Length(n))
      vDSP_vmul(r, 1, s, 1, &r, 1, vDSP_Length(n))
      // grad = Xᵀ r + l2 w
      vDSP_mmul(flatT, 1, r, 1, &grad, 1, vDSP_Length(d), 1, vDSP_Length(n))
      var reg = l2
      vDSP_vsma(w, 1, &reg, grad, 1, &grad, 1, vDSP_Length(d))
      var gradB: Float = 0
      vDSP_sve(r, 1, &gradB, vDSP_Length(n))
      // w -= lr * grad; b -= lr * gradB
      var step = -lr
      vDSP_vsma(grad, 1, &step, w, 1, &w, 1, vDSP_Length(d))
      b -= lr * gradB
    }
    return LogisticClassifier(w: w, b: b)
  }
}
