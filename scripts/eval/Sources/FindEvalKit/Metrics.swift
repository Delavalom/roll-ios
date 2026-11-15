import Foundation

/// Ranking metrics over a ranked id list and a query's labels. Unlabelled results count as not relevant (pooled judging
/// assumes what nobody pooled is wrong) and are counted separately, so a variant that brings in unjudged results shows it.
public enum FindMetrics {
  /// Relevant among the first `k`, divided by `k` (a short answer has holes, like the list a person sees).
  public static func precision(at k: Int, ranked: [String], relevant: Set<String>) -> Double {
    guard k > 0 else { return 0 }
    return Double(ranked.prefix(k).filter(relevant.contains).count) / Double(k)
  }

  /// Of the first `k`, how many have no label at all.
  public static func unjudged(at k: Int, ranked: [String], judged: Set<String>) -> Int {
    ranked.prefix(k).filter { !judged.contains($0) }.count
  }

  /// nDCG@k with binary gain: DCG = sum over relevant ranks i (1-based) of 1 / log2(i + 1), divided by the DCG of
  /// `min(totalRelevant, k)` relevant results at the top. Nil when nothing relevant is known.
  public static func ndcg(at k: Int, ranked: [String], relevant: Set<String>, totalRelevant: Int? = nil) -> Double? {
    let total = totalRelevant ?? relevant.count
    guard total > 0, k > 0 else { return nil }
    var dcg = 0.0
    for (i, id) in ranked.prefix(k).enumerated() where relevant.contains(id) { dcg += 1 / log2(Double(i + 2)) }
    var ideal = 0.0
    for i in 0..<min(total, k) { ideal += 1 / log2(Double(i + 2)) }
    return dcg / ideal
  }

  /// Relevant among the first `k`, divided by every relevant id known for the query (pooled recall). Nil without any.
  public static func recall(at k: Int, ranked: [String], relevant: Set<String>) -> Double? {
    guard !relevant.isEmpty else { return nil }
    return Double(ranked.prefix(k).filter(relevant.contains).count) / Double(relevant.count)
  }
}

/// One variant on one query, identifier-free.
public struct VariantScore: Codable, Sendable, Equatable {
  public var pAt10: Double?
  public var pAt20: Double?
  public var pAt50: Double?
  public var unjudgedAt10: Int
  public var unjudgedAt20: Int
  public var unjudgedAt50: Int
  /// Results labelled "unsure" in the first 20 (counted as not relevant in P@k).
  public var unsureAt20: Int
  public var ndcgAt20: Double?
  public var recallAt100: Double?
  public var strong: Int
  public var weaker: Int
  /// For `expect: nothing`: true when the variant showed no strong match. Nil for real queries.
  public var refused: Bool?
  /// For `expect: matches`: true when it showed no strong match (a false "nothing found").
  public var falseRefusal: Bool?
  public var elapsedMs: Double

  /// Scores `run` against `labels` (+ `extraRelevant`, e.g. album members). Precision and nDCG are for real queries
  /// only; a nonsense query is graded on `refused`.
  public static func score(run: VariantRun, labels: Labels, extraRelevant: Set<String> = [],
                           expect: FindExpectation) -> VariantScore {
    let relevant = Set(labels.relevant).union(extraRelevant)
    let judged = labels.judged.union(extraRelevant)
    let unsure = Set(labels.unsure).subtracting(extraRelevant)
    let real = expect == .matches
    return VariantScore(
      pAt10: real ? FindMetrics.precision(at: 10, ranked: run.top, relevant: relevant) : nil,
      pAt20: real ? FindMetrics.precision(at: 20, ranked: run.top, relevant: relevant) : nil,
      pAt50: real ? FindMetrics.precision(at: 50, ranked: run.top, relevant: relevant) : nil,
      unjudgedAt10: FindMetrics.unjudged(at: 10, ranked: run.top, judged: judged),
      unjudgedAt20: FindMetrics.unjudged(at: 20, ranked: run.top, judged: judged),
      unjudgedAt50: FindMetrics.unjudged(at: 50, ranked: run.top, judged: judged),
      unsureAt20: run.top.prefix(20).filter(unsure.contains).count,
      ndcgAt20: real ? FindMetrics.ndcg(at: 20, ranked: run.top, relevant: relevant) : nil,
      recallAt100: real ? FindMetrics.recall(at: 100, ranked: run.top, relevant: relevant) : nil,
      strong: run.strong, weaker: run.weaker,
      refused: real ? nil : run.strong == 0,
      falseRefusal: real ? run.strong == 0 : nil,
      elapsedMs: run.elapsedMs)
  }
}

/// One query's evidence file: counts only. A private query keeps neither its name nor its text.
public struct QueryEvidence: Codable, Sendable, Equatable {
  public var name: String
  public var group: String
  public var expect: FindExpectation
  /// Relevant ids known (judged relevant, plus album members).
  public var relevantKnown: Int
  public var judged: Int
  /// Album members with a vector (they count as relevant).
  public var albumMembers: Int?
  /// Album members without a vector (newer than the index): left out of every metric.
  public var albumMembersWithoutVector: Int?
  public var variants: [String: VariantScore]

  public init(name: String, group: String, expect: FindExpectation, relevantKnown: Int, judged: Int,
              albumMembers: Int?, albumMembersWithoutVector: Int? = nil, variants: [String: VariantScore]) {
    self.name = name; self.group = group; self.expect = expect; self.relevantKnown = relevantKnown
    self.judged = judged; self.albumMembers = albumMembers; self.albumMembersWithoutVector = albumMembersWithoutVector
    self.variants = variants
  }
}

/// Means over a set of queries for one variant.
public struct GroupMeans: Codable, Sendable, Equatable {
  public var queries: Int
  public var pAt10: Double?
  public var pAt20: Double?
  public var pAt50: Double?
  public var unjudgedAt20: Double?
  public var ndcgAt20: Double?
  public var recallAt100: Double?
  public var meanStrong: Double?
  public var medianStrong: Double?
  public var meanWeaker: Double?
  /// Nonsense queries with no strong match / nonsense queries.
  public var refusedShare: Double?
  /// Real queries that showed nothing.
  public var falseRefusals: Int?
  public var meanElapsedMs: Double?

  /// Means over the queries where each metric is defined (precision over real queries, nDCG and recall over those
  /// with a known relevant id, refusals over nonsense ones).
  public static func of(_ scores: [VariantScore]) -> GroupMeans {
    let refusals = scores.compactMap(\.refused)
    let falses = scores.compactMap(\.falseRefusal)
    return GroupMeans(
      queries: scores.count,
      pAt10: mean(scores.compactMap(\.pAt10)), pAt20: mean(scores.compactMap(\.pAt20)),
      pAt50: mean(scores.compactMap(\.pAt50)),
      unjudgedAt20: mean(scores.map { Double($0.unjudgedAt20) }),
      ndcgAt20: mean(scores.compactMap(\.ndcgAt20)), recallAt100: mean(scores.compactMap(\.recallAt100)),
      meanStrong: mean(scores.map { Double($0.strong) }), medianStrong: median(scores.map { Double($0.strong) }),
      meanWeaker: mean(scores.map { Double($0.weaker) }),
      refusedShare: refusals.isEmpty ? nil : Double(refusals.filter { $0 }.count) / Double(refusals.count),
      falseRefusals: falses.isEmpty ? nil : falses.filter { $0 }.count,
      meanElapsedMs: mean(scores.map(\.elapsedMs)))
  }

  public static func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }

  public static func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted(), m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
  }
}

/// `summary.json`: per variant, means per group and over everything. Identifier-free.
public struct FindSummary: Codable, Sendable, Equatable {
  public var variants: [String]
  public var queries: Int
  /// group → variant → means
  public var groups: [String: [String: GroupMeans]]
  /// variant → means over every query (precision over the real ones, refusals over the nonsense ones)
  public var overall: [String: GroupMeans]

  public static func make(_ evidence: [QueryEvidence], variants: [String]) -> FindSummary {
    var groups: [String: [String: GroupMeans]] = [:]
    for g in Set(evidence.map(\.group)) {
      let rows = evidence.filter { $0.group == g }
      groups[g] = Dictionary(uniqueKeysWithValues: variants.map { v in (v, GroupMeans.of(rows.compactMap { $0.variants[v] })) })
    }
    let overall = Dictionary(uniqueKeysWithValues: variants.map { v in
      (v, GroupMeans.of(evidence.compactMap { $0.variants[v] }))
    })
    return FindSummary(variants: variants, queries: evidence.count, groups: groups, overall: overall)
  }
}
