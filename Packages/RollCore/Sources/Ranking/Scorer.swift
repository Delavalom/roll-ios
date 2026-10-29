import Accelerate
import Store

/// Scores one asset for one swipefile (spec §5).
///
/// - Trained (the swipefile has a classifier of the vector's width): `prob(v) + boost`.
/// - Untrained: `max over prompts of cos(prompt, v) + 0.5 · mean cos(example, v) + boost`; each term
///   is 0 when there are no prompts / examples.
///
/// `SwipefileEngine` scores the whole library at once with matrix-vector products over unit
/// vectors (dot = cosine), then feeds the same `combine` / `trained` formulas.
public enum Scorer {
  public static let exampleWeight: Float = 0.5

  public static func score(vector: [Float], swipefile: SwipefileRecord, promptVectors: [[Float]],
                           exampleVectors: [[Float]], record: AssetRecord) -> Float {
    let boost = boost(swipefile: swipefile, record: record)
    if let blob = swipefile.classifier, let model = LogisticClassifier(blob: blob, dimensions: vector.count) {
      return trained(probability: model.prob(vector), boost: boost)
    }
    let prompts = promptVectors.map { cosine($0, vector) }
    let examples = exampleVectors.map { cosine($0, vector) }
    let meanExample = examples.isEmpty ? nil : examples.reduce(0, +) / Float(examples.count)
    return combine(promptSimilarities: prompts, meanExampleSimilarity: meanExample, boost: boost)
  }

  /// The untrained formula from precomputed similarities.
  public static func combine(promptSimilarities: [Float], meanExampleSimilarity: Float?, boost: Float) -> Float {
    (promptSimilarities.max() ?? 0) + exampleWeight * (meanExampleSimilarity ?? 0) + boost
  }

  public static func trained(probability: Float, boost: Float) -> Float { probability + boost }

  /// The preset's signal boost; 0 for custom swipefiles.
  public static func boost(swipefile: SwipefileRecord, record: AssetRecord) -> Float {
    Preset(swipefile: swipefile)?.signalBoost(record) ?? 0
  }

  /// Cosine similarity; 0 if either vector is zero.
  public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "vectors differ in length")
    let n = vDSP_Length(a.count)
    var dot: Float = 0, aa: Float = 0, bb: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, n)
    vDSP_svesq(a, 1, &aa, n)
    vDSP_svesq(b, 1, &bb, n)
    let denom = (aa * bb).squareRoot()
    return denom > 0 ? dot / denom : 0
  }
}
