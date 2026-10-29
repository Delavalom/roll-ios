import Foundation
import Store

// MARK: - Ask Roll search

extension SwipefileEngine {
  /// Photos matching a sentence across the whole live index (`PhotoSearch`), decided or not. A blank query
  /// matches nothing. `elapsed` covers embedding the query, scoring every vector and ranking: the "compared
  /// on this iPhone in …" the answer shows is this measurement.
  ///
  /// Uses the piles' fast path (`poolScores`: in-memory rows, one matrix product, integer rows). A photo qualifies
  /// by standing out on this query's own scale over the whole index (`QueryScale`, z >= `QueryScale.zGate`), or by
  /// holding at least `LibrarySearch.coverageGate` of the query's words in its text (screenshots and documents,
  /// `keywordCoverage`). Only the qualified photos' search fields are read from the database.
  public func search(_ query: String, refinement: PhotoSearch.Refinement = .init()) async throws -> PhotoSearch.Result {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return PhotoSearch.Result() }
    guard embedder.revision == vectors.revision else { throw EngineError.revisionMismatch }
    guard embedder.dimensions == vectors.dimensions else {
      throw EngineError.dimensionMismatch(embedder: embedder.dimensions, index: vectors.dimensions)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let vector = Self.normalized(try await embedder.embed(query: query))
    let terms = SearchTerms.queryTerms(query)
    let coverage = terms.isEmpty ? [:] : (try await keywordCoverage?(terms) ?? [:])
    let pool = try await poolScores(queries: [vector], preset: nil, filter: .none, decidedIn: nil, excluding: [])
    let scale = QueryScale(pool.dots, query: 0)
    let dots = pool.dots(query: 0)

    var picked: [String: (score: Float, coverage: Double)] = [:]
    for k in 0..<pool.count {
      let standsOut = scale.z(dots[k]) >= QueryScale.zGate
      guard standsOut || !coverage.isEmpty else { continue }
      let id = pool.id(k)
      let words = coverage[id] ?? 0
      if standsOut || words >= LibrarySearch.coverageGate { picked[id] = (dots[k], words) }
    }
    let assets = try await repositories.searchAssets(ids: Array(picked.keys))
    let scored = assets.compactMap { asset in
      picked[asset.id].map { PhotoSearch.Scored(asset: asset, score: $0.score, coverage: $0.coverage) }
    }
    var result = PhotoSearch.rank(scored, scale: scale, compared: pool.count, lookup: SearchTerms.isLookup(terms),
                                  refinement: refinement, now: now())
    result.elapsed = clock.now - start
    return result
  }
}
