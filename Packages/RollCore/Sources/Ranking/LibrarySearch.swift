import Embedding
import Foundation
import Store

/// A typed query over the whole library: meaning from the embedding, words from the text index (OCR of
/// screenshots and documents), fused the way DigUp does it. **The app's Ask Roll goes through
/// `SwipefileEngine.search` (`PhotoSearch`)**, which uses this type's gates, weights and `fusedScore` over the
/// piles' fast path; this engine-free version also returns text-only hits (words, no vector) and is kept for
/// that and for its tests.
///
/// 1. **Meaning.** The query is embedded and scored against every stored vector in one `dotAll`; each
///    score goes on this query's scale (`QueryScale`), so `z` says how far an asset stands out.
/// 2. **Words.** `keywordCoverage` gets the query's content words (`SearchTerms.queryTerms`) and
///    returns, per asset id, the share of them found in its text (0…1). Nil when there is no text index.
/// 3. **Candidates** are assets with `z >= zGate`, or with `coverage >= coverageGate`: a code or name
///    the embedding can't hold is rescued by its words. Nothing else is returned, so a query nothing
///    stands out for gets an honest empty result.
/// 4. **Score** = `meaningWeight · max(z, 0) + wordsWeight · coverage^1.5`. A lookup query (only codes
///    and long numbers, `SearchTerms.isLookup`) weighs words double and meaning half.
/// 5. Best first (ties by id); `weak` marks hits under `foldRatio × top` (`Fold`), for the UI's
///    "N weaker matches".
///
/// Only live assets are returned: vectors count when their asset is live and flagged embedded
/// (`Repositories.liveEmbeddedIds`, the same set `rankingCandidates(embeddedOnly:)` reads), and a
/// text-only hit must be a live row (`Repositories.assetRefs`). The scale itself is computed over every
/// stored vector, as for piles; reconcile keeps the index to live rows, so the difference is a few
/// vectors waiting to be purged.
///
/// The gate and fold ratio come from the pile eval (2026-10-29); the word weights are DigUp's, not yet tuned on Roll.
public struct LibrarySearch: Sendable {
  public struct Hit: Sendable, Equatable, Identifiable {
    public var id: String
    /// Fused score (`fusedScore`), for ordering and folding.
    public var score: Float
    /// How far the asset stands out for this query (`QueryScale.z`); nil when it has no vector.
    public var z: Float?
    /// Share of the query's words found in the asset's text (0 without a text index).
    public var coverage: Double
    /// Below `foldRatio × top`: show it under "weaker matches".
    public var weak: Bool

    public init(id: String, score: Float, z: Float?, coverage: Double, weak: Bool) {
      self.id = id; self.score = score; self.z = z; self.coverage = coverage; self.weak = weak
    }
  }

  /// meaning counts when z reaches this.
  public static let zGate: Float = QueryScale.zGate
  /// words alone count from this share of the query's words (DigUp: 0.5).
  public static let coverageGate: Double = 0.5
  /// fold ratio.
  public static let foldRatio: Float = Fold.defaultRatio
  /// weight of `max(z, 0)`.
  public static let meaningWeight: Float = 1
  /// weight of `coverage^1.5` (DigUp: 2).
  public static let wordsWeight: Float = 2
  /// A lookup query multiplies meaning by this and words by `lookupWordsFactor`.
  public static let lookupMeaningFactor: Float = 0.5
  public static let lookupWordsFactor: Float = 2

  public typealias KeywordCoverage = @Sendable ([String]) async throws -> [String: Double]

  private let embedder: any Embedder
  private let vectors: VectorStore
  private let repositories: Repositories
  private let keywordCoverage: KeywordCoverage?

  public init(embedder: any Embedder, vectors: VectorStore, repositories: Repositories,
              keywordCoverage: KeywordCoverage?) {
    self.embedder = embedder
    self.vectors = vectors
    self.repositories = repositories
    self.keywordCoverage = keywordCoverage
  }

  /// The fused score: `m · max(z, 0) + w · coverage^1.5`, with `m`, `w` from the weights above
  /// (lookup: `m × 0.5`, `w × 2`). A missing z counts as 0.
  public static func fusedScore(z: Float?, coverage: Double, lookup: Bool) -> Float {
    let m = lookup ? meaningWeight * lookupMeaningFactor : meaningWeight
    let w = lookup ? wordsWeight * lookupWordsFactor : wordsWeight
    return m * max(z ?? 0, 0) + w * Float(pow(min(max(coverage, 0), 1), 1.5))
  }

  /// Up to `limit` hits, best first. Empty for blank text or when nothing passes either gate.
  /// Throws `SwipefileEngine.EngineError.revisionMismatch` / `.dimensionMismatch` when the embedder
  /// doesn't match the index (its query vector would live in another space).
  public func search(_ text: String, limit: Int = 50) async throws -> [Hit] {
    guard limit > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    guard embedder.revision == vectors.revision else { throw SwipefileEngine.EngineError.revisionMismatch }
    guard embedder.dimensions == vectors.dimensions else {
      throw SwipefileEngine.EngineError.dimensionMismatch(embedder: embedder.dimensions, index: vectors.dimensions)
    }
    let terms = SearchTerms.queryTerms(text)
    let lookup = SearchTerms.isLookup(terms)

    // Meaning: every vector on this query's scale; only live, flagged rows can be hits.
    let query = Self.normalized(try await embedder.embed(query: text))
    let dots = try await scoreAll(query)
    let scale = QueryScale(dots, query: 0)
    let live = Set(try await repositories.liveEmbeddedIds())
    var meaning: [String: Float] = [:]
    for (row, id) in dots.ids.enumerated() where live.contains(id) { meaning[id] = scale.z(dots[row, 0]) }

    // Words: coverage per asset; ids without a live vector must still be live rows.
    var coverage: [String: Double] = [:]
    if let keywordCoverage, !terms.isEmpty {
      coverage = try await keywordCoverage(terms).filter { $0.value > 0 }
      let unknown = coverage.keys.filter { meaning[$0] == nil }
      if !unknown.isEmpty {
        let liveRows = Set(try await repositories.assetRefs(ids: Array(unknown)).filter { !$0.deleted }.map(\.id))
        for id in unknown where !liveRows.contains(id) { coverage[id] = nil }
      }
    }

    var hits: [Hit] = []
    for (id, z) in meaning where z >= Self.zGate {
      let c = coverage[id] ?? 0
      hits.append(Hit(id: id, score: Self.fusedScore(z: z, coverage: c, lookup: lookup), z: z, coverage: c, weak: false))
    }
    for (id, c) in coverage where c >= Self.coverageGate && !(meaning[id].map { $0 >= Self.zGate } ?? false) {
      let z = meaning[id]
      hits.append(Hit(id: id, score: Self.fusedScore(z: z, coverage: c, lookup: lookup), z: z, coverage: c, weak: false))
    }
    hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    if let top = hits.first?.score {
      for i in hits.indices { hits[i].weak = Fold.isWeak(hits[i].score, top: top, ratio: Self.foldRatio) }
    }
    return Array(hits.prefix(limit))
  }

  /// The one place that scores the index, so lane L1's faster product can replace it alone.
  private func scoreAll(_ query: [Float]) async throws -> DotProducts {
    try await vectors.dotAll([query])
  }

  private static func normalized(_ v: [Float]) -> [Float] {
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? v.map { $0 / norm } : v
  }
}
