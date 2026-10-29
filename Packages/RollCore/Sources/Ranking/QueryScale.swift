import Store

/// One query's scores on its own scale: how far each score stands out from the whole index.
///
/// Every stored vector is scored anyway (`VectorStore.dotAll`), so the mean and standard deviation of
/// one query's scores come for free. `z = (score − mean) / deviation` replaces a fixed cosine floor:
/// a match is something that stands out for *this* query, which gives an honest "nothing found" when
/// nothing does, whatever level the model puts the query's cosines at. Roll's vectors are all image
/// embeddings (a video is one preview frame), so one mean per query is enough.
///
/// For one query, z is a strictly increasing function of the score, so it never reorders hits.
///
/// **Degenerate indexes.** With fewer than `minimumCount` vectors, or a deviation under
/// `minimumDeviation` (every score about the same, e.g. a zero query), the mean and deviation say
/// nothing. Then `z` falls back to the raw cosine scaled so that `rawFloor` lands on `zGate`
/// (`zGate · score / rawFloor`): `passes` becomes today's fixed floor, `score >= rawFloor`, and the
/// order is still the cosine order.
///
/// **What the gate does not do.** A z gate passes whatever stands out. For a query whose scores are
/// bell-shaped with no real matches, about 2 % of the index sits above z = 2 by chance; and when more
/// than about a fifth of the index truly matches (bimodal scores), the matches' z stays under 2. L5's
/// eval has to check both on the real library before these numbers are final.
///
/// `zGate` 2.0 was chosen by the pile eval (2026-10-29: `docs/investigations/2026-10-29-pile-eval.md`).
public struct QueryScale: Sendable, Equatable {
  /// Provisional: a score passes when it stands this many deviations above the mean (DigUp: 2.0).
  public static let zGate: Float = 2
  /// Provisional: below this many vectors the scale is degenerate.
  public static let minimumCount = 30
  /// Provisional: a deviation under this (cosine units) is degenerate.
  public static let minimumDeviation: Float = 0.005
  /// The degenerate fallback's cosine floor (the old `SwipefileEngine.untrainedFloor`).
  public static let rawFloor: Float = 0.2

  /// How many scores set the scale.
  public let count: Int
  public let mean: Float
  /// Population standard deviation.
  public let deviation: Float

  /// True when the scale can't be trusted and `z` is the raw-floor fallback.
  public var isDegenerate: Bool { count < Self.minimumCount || !(deviation >= Self.minimumDeviation) }

  /// The scale of one query's scores over the whole index.
  public init(scores: [Float]) {
    self.init(scores: scores, queryCount: 1, query: 0)
  }

  /// The scale of query `query` in a row-major `rows × queryCount` matrix (`DotProducts.scores`).
  public init(scores: [Float], queryCount: Int, query: Int) {
    precondition(queryCount > 0 && (0..<queryCount).contains(query), "query out of range")
    precondition(scores.count % queryCount == 0, "scores aren't rows × queryCount")
    let n = scores.count / queryCount
    var sum = 0.0
    var i = query
    while i < scores.count { sum += Double(scores[i]); i += queryCount }
    let mean = n > 0 ? sum / Double(n) : 0
    var squares = 0.0
    i = query
    while i < scores.count {
      let d = Double(scores[i]) - mean
      squares += d * d
      i += queryCount
    }
    self.count = n
    self.mean = Float(mean)
    self.deviation = n > 0 ? Float((squares / Double(n)).squareRoot()) : 0
  }

  /// The scale of query `query` in `dots` (query-major: its scores are one contiguous block).
  public init(_ dots: DotProducts, query: Int) {
    self.init(scores: Array(dots.scores(forQuery: query)))
  }

  /// `z` as `a * score + b`, for whole-array arithmetic (`vDSP_vsmsa`): both the scale and the degenerate
  /// fallback are linear in the score.
  public var linear: (a: Float, b: Float) {
    isDegenerate ? (Self.zGate / Self.rawFloor, 0) : (1 / deviation, -mean / deviation)
  }

  /// `score` in deviations from the mean, or the raw-floor fallback when the scale is degenerate.
  public func z(_ score: Float) -> Float {
    isDegenerate ? Self.zGate * score / Self.rawFloor : (score - mean) / deviation
  }

  /// Whether `score` stands out: `z(score) >= gate`.
  public func passes(_ score: Float, gate: Float = QueryScale.zGate) -> Bool {
    z(score) >= gate
  }
}

/// Several queries scored in one `dotAll` (a pile's prompts, plus the mean example vector if any).
///
/// **How queries combine:** each query is put on its own scale, then a row takes its best z
/// (`max_j z_j`). A prompt that sits close to everything (a broad one) can't drown a narrow one: a
/// row counts when it stands out for *some* query. A signal boost (`Preset.signalBoost`) is in cosine
/// units, so it is added to each raw score before scaling: `max_j z_j(score_j + boost)`. With one
/// query and no boost this is `QueryScale.z`; in the degenerate fallback it is `score + boost` against
/// the raw floor, which is the old untrained rule for a single prompt.
public struct PileScale: Sendable {
  /// One scale per query (column).
  public let scales: [QueryScale]
  public let queryCount: Int
  private let scores: [Float]

  /// `scores` is row-major, `rows × queryCount`.
  public init(scores: [Float], queryCount: Int) {
    self.scores = scores
    self.queryCount = queryCount
    self.scales = (0..<queryCount).map { QueryScale(scores: scores, queryCount: queryCount, query: $0) }
  }

  /// `dots.scores` is query-major (`DotProducts`), so it is transposed to rows first.
  public init(_ dots: DotProducts) {
    let n = dots.ids.count, m = dots.queryCount
    var rowMajor = [Float](repeating: 0, count: n * m)
    for j in 0..<m { for (r, v) in dots.scores(forQuery: j).enumerated() { rowMajor[r * m + j] = v } }
    self.init(scores: rowMajor, queryCount: m)
  }

  public var rowCount: Int { queryCount > 0 ? scores.count / queryCount : 0 }

  /// The row's best z over all queries; `-infinity` when there are no queries.
  public func z(row: Int, boost: Float = 0) -> Float {
    var best = -Float.infinity
    let base = row * queryCount
    for j in 0..<queryCount { best = max(best, scales[j].z(scores[base + j] + boost)) }
    return best
  }

  public func passes(row: Int, boost: Float = 0, gate: Float = QueryScale.zGate) -> Bool {
    z(row: row, boost: boost) >= gate
  }
}

/// Folding weak matches under "N weaker matches": a hit is strong when it scores at least
/// `ratio × top`. DigUp's evals found 0.5 cut the list by about 4x without folding an expected
/// answer. Roll's pile eval (2026-10-29) chose 0.4: at z >= 2 it folds 14 % of true matches and what it folds is
/// less precise than what stays (0.23 vs 0.34); 0.5 folded 35 %, close to a random cut.
public enum Fold {
  public static let defaultRatio: Float = 0.4

  /// How many of `scoresSortedDesc` (best first) are strong. A top that isn't positive gives no
  /// reference, so nothing folds.
  public static func strongCount(_ scoresSortedDesc: [Float], ratio: Float = defaultRatio) -> Int {
    guard let top = scoresSortedDesc.first, top > 0 else { return scoresSortedDesc.count }
    return scoresSortedDesc.prefix { $0 >= top * ratio }.count
  }

  /// The per-hit rule behind `strongCount`, for lists not sorted by this score: weak when below
  /// `ratio × top` (`top` is the best score in the list). Never weak when `top` isn't positive.
  public static func isWeak(_ score: Float, top: Float, ratio: Float = defaultRatio) -> Bool {
    top > 0 && score < top * ratio
  }
}
