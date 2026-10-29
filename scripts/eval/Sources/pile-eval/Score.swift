import EmbeddingIndex
import Foundation
import PileEvalKit

/// Today's untrained-pile floor (`SwipefileEngine.untrainedFloor`; here on the bare cosine, without preset boosts).
let cosineFloor: Float = 0.2
let zGates: [Float] = [1.5, 2.0, 2.5, 3.0]
let foldRatios: [Double] = [0.4, 0.5, 0.6]
/// The z gate at which each query's results are broken down by rule (`QueryReport.composition`).
let compositionGate: Float = 2.0

struct Meta: Codable {
  var revision: String
  var dimensions: Int
  var vectors: Int
  /// Rule → labelled assets that have a vector.
  var labels: [String: Int]
  var gates: [String]
  var foldRatios: [Double]
  var compositionGate: Double
}

/// Scores every query against the whole index with `VectorIndex.dotAll` (one matrix product, the call lane L1 moves
/// `VectorStore` to), labels from `db`, and writes identifier-free JSON to `out`: `meta.json`, `summary-<group>.json`
/// (one row per gate; groups: labelled = visible rules, controls, nonsense, unlabelled) and `queries/<query>.json`.
func scoreQueries(spec: PileSpec, vectorsURL: URL, indexURL: URL, dbPath: String, out: URL) throws {
  let qv = try JSONDecoder().decode(QueryVectors.self, from: Data(contentsOf: vectorsURL))
  // Throws revisionMismatch unless the query vectors come from the model that built the index.
  let index = try VectorIndex(url: indexURL, dimensions: qv.dimensions, modelRevision: qv.revision)
  let texts = Array(qv.vectors.keys).sorted()
  let bulk = index.dotAll(texts.map { qv.vectors[$0]! })
  let n = bulk.ids.count
  let row = Dictionary(uniqueKeysWithValues: texts.enumerated().map { ($1, $0) })
  let position = Dictionary(uniqueKeysWithValues: bulk.ids.enumerated().map { ($1, $0) })

  let labels = try LabelSource(path: dbPath)
  var positivesByRule: [String: Set<Int>] = [:]
  for (name, rule) in spec.rules {
    positivesByRule[name] = Set(try labels.ids(where: rule.sql).compactMap { position[$0] })
  }

  var reports: [QueryReport] = []
  for q in spec.queries {
    let prompts = try q.prompts()
    guard prompts.allSatisfy({ row[$0] != nil }) else {
      throw PileSpec.Invalid(description: "\(q.name): no vector for a prompt; run embed again")
    }
    let rows = prompts.map { Array(bulk.scores(forQuery: row[$0]!)) }
    let cos = QueryScale.bestPerVector(rows)
    let z = QueryScale.bestPerVector(rows.map(QueryScale.z))
    let labelled = q.expect == .matches ? q.rule.flatMap { positivesByRule[$0] } : nil
    let positives = labelled?.isEmpty == true ? nil : labelled  // a rule with no members can't grade anything
    let order = ScoreOrder.bestFirst(cos)
    var gates = [Gate.evaluate(name: "cos>=0.2", scores: cos, threshold: cosineFloor, positives: positives,
                               foldRatios: foldRatios)]
    for g in zGates {
      gates.append(Gate.evaluate(name: "z>=\(g)", scores: z, threshold: g, positives: positives, foldRatios: foldRatios))
    }
    let mean = cos.reduce(0.0) { $0 + Double($1) } / Double(n)
    let sd = (cos.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(n)).squareRoot()
    var report = QueryReport(
      name: q.name, rule: q.rule, expect: q.expect, prompts: prompts.count, positives: labelled?.count ?? 0,
      cosMean: mean, cosSD: sd, cosTop: Double(cos.max() ?? 0), zTop: Double(z.max() ?? 0),
      precisionAt20: positives.map { Metrics.precision(at: 20, order: order, positives: $0) },
      recallAt200: positives.flatMap { Metrics.recall(at: 200, order: order, positives: $0) },
      cappedRecallAt200: positives.flatMap { Metrics.cappedRecall(at: 200, order: order, positives: $0) },
      gates: gates)
    report.composition = Gate.composition(scores: z, threshold: compositionGate, rules: positivesByRule)
    reports.append(report)
  }

  func group(_ r: QueryReport) -> String {
    switch r.expect {
    case .nothing: return "nonsense"
    case .unlabelled: return "unlabelled"
    case .matches:
      guard r.positives > 0 else { return "unlabelled" }
      return spec.rules[r.rule ?? ""]?.visible == true ? "labelled" : "controls"
    }
  }
  let queriesDir = out.appending(path: "queries")
  try FileManager.default.createDirectory(at: queriesDir, withIntermediateDirectories: true)
  for name in ["labelled", "controls", "nonsense", "unlabelled"] {
    try writeRounded(Summary.byGate(reports.filter { group($0) == name }), to: out.appending(path: "summary-\(name).json"))
  }
  let meta = Meta(revision: qv.revision, dimensions: qv.dimensions, vectors: n,
                  labels: positivesByRule.mapValues(\.count), gates: reports.first?.gates.map(\.gate) ?? [],
                  foldRatios: foldRatios, compositionGate: Double(compositionGate))
  try writeRounded(meta, to: out.appending(path: "meta.json"))
  for r in reports { try writeRounded(r, to: queriesDir.appending(path: "\(slug(r.name)).json")) }
}

/// "control: video frame" → "control-video-frame".
func slug(_ name: String) -> String {
  name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
}

/// JSON with doubles rounded to 4 decimals (keeps the evidence files small and readable).
func writeRounded(_ value: some Encodable, to url: URL) throws {
  let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  func round(_ any: Any) -> Any {
    if let d = any as? [String: Any] { return d.mapValues(round) }
    if let a = any as? [Any] { return a.map(round) }
    if let x = any as? NSNumber, CFNumberIsFloatType(x) {
      // Via the shortest decimal text, so 0.4 is written as 0.4, not 0.40000000000000002.
      return NSDecimalNumber(string: "\((x.doubleValue * 10_000).rounded() / 10_000)")
    }
    return any
  }
  let data = try JSONSerialization.data(withJSONObject: round(raw), options: [.sortedKeys, .prettyPrinted])
  try data.write(to: url)
}
