import Foundation
import Store

// MARK: - Ask Roll search

extension SwipefileEngine {
  /// Photos matching a sentence across the whole live index (`PhotoSearch`), decided or not. A blank query
  /// matches nothing. `elapsed` covers embedding the query, scoring every vector and ranking: the "compared
  /// on this iPhone in …" the answer shows is this measurement.
  ///
  /// `find` with `FindConfig.default` (today's rule, V0): a photo qualifies by standing out on this query's own scale
  /// over the whole index (`QueryScale`, z >= `QueryScale.zGate`), or by holding at least `LibrarySearch.coverageGate`
  /// of the query's words in its text (screenshots and documents, `keywordCoverage`). Uses the piles' fast path
  /// (`poolScores`); only the qualified photos' search fields are read from the database.
  public func search(_ query: String, refinement: PhotoSearch.Refinement = .init()) async throws -> PhotoSearch.Result {
    try await find(query, config: .default, refinement: refinement).photoSearch
  }
}
