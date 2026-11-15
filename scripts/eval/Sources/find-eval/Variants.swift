import FindEvalKit
import Foundation
import Ranking
import Store

/// **The variant seam.** A variant answers one query from the library as the app would, best first, split into what
/// shows (strong) and what folds (weaker). `pool` times `answer`, keeps the top of it and the counts.
///
/// To add one (V2–V5 from RollCore's `FindSearch`): write a `FindVariant` whose `answer` builds `FindSearch`'s inputs
/// from `FindLibrary` and maps its result to a `VariantAnswer`, then list it in `Variants.all`. What `FindLibrary`
/// offers:
/// - `scores(text)` / `dots(text)`: a query text's cosine with every stored vector (`ids` order), for every text
///   `embed` produced (`query.texts`: the bare text and each template); `QueryScale(dots, query: 0)` is the app's scale.
/// - `pooled[row]` / `poolCount`: the live, embedded rows (the app's search pool).
/// - `repositories`: RollCore's own reads over a clone of the database (`keywordCoverage`, `searchAssets`, and
///   whatever schema v11 adds: `event`, location columns, once this checkout's RollCore has them).
/// - `export[id]`: created, lat/lon, media type, albums (phone export; empty without `--export`); `vision[id]`: Vision
///   labels (V4); `index.vector(for: id)`: image vectors (V5's photo-to-photo seeds); `labels(slug)`: labels so far
///   (V5's picked relevant results); `now`: the export's newest date (for "last summer").
/// A variant that needs text the spec didn't embed should add a template to the spec, not embed here: `pool` stays
/// model-free.
protocol FindVariant: Sendable {
  var name: String { get }
  var about: String { get }
  func answer(_ query: ResolvedQuery, in library: FindLibrary) async throws -> VariantAnswer
}

struct VariantAnswer {
  /// Best first: shown on screen.
  var strong: [String]
  /// Best first: folded under "N weaker matches".
  var weaker: [String]
  /// Identifier-free numbers worth keeping (top z, gate used, ...).
  var notes: [String: Double] = [:]

  var ranked: [String] { strong + weaker }

  init(strong: [String], weaker: [String], notes: [String: Double] = [:]) {
    self.strong = strong; self.weaker = weaker; self.notes = notes
  }

  init(_ result: PhotoSearch.Result, notes: [String: Double] = [:]) {
    self.init(strong: result.matches.map(\.id), weaker: result.weaker.map(\.id), notes: notes)
  }
}

enum Variants {
  static let all: [any FindVariant] = [
    PhotoSearchVariant(name: "V0", about: "today: SwipefileEngine.search + PhotoSearch.rank on the bare text "
                       + "(z >= 2 over the whole index, words from the text index, fold 0.4)",
                       texts: { [$0.text] }),
    PhotoSearchVariant(name: "V1", about: "provisional: best z over the bare text and \"a photo of {text}\", "
                       + "then PhotoSearch.rank as V0",
                       texts: { [$0.text, ResolvedQuery.apply("a photo of {text}", to: $0.text)] }),
    PhotoSearchVariant(name: "V1t", about: "provisional: \"a photo of {text}\" alone instead of the bare text",
                       texts: { [ResolvedQuery.apply("a photo of {text}", to: $0.text)] }),
    PhotoSearchVariant(name: "V1x", about: "provisional: best z over the bare text and every template of the spec",
                       texts: { $0.texts }),
  ]

  static func named(_ names: [String]) throws -> [any FindVariant] {
    try names.map { name in
      guard let v = all.first(where: { $0.name == name }) else {
        throw FindSpec.Invalid("unknown variant \(name) (known: \(all.map(\.name).joined(separator: ", ")))")
      }
      return v
    }
  }
}

/// Today's typed search (`SwipefileEngine.search`) on one or more embedded texts.
///
/// With one text this is exactly the app: cosines with every stored vector, the query's scale over the whole index
/// (`QueryScale(dots, query: 0)`), a pool entry picked when z >= `QueryScale.zGate` or when it holds at least
/// `LibrarySearch.coverageGate` of the query's words (`Repositories.keywordCoverage` of `SearchTerms.queryTerms`),
/// `Repositories.searchAssets` for the picked rows, then `PhotoSearch.rank` (fused score, fold), no refinement.
///
/// With several texts a row's z is the best of each text's own z (`PileScale`'s rule: a row counts when it stands out
/// for some text). `PhotoSearch.rank` takes cosines and one scale, so the best z is mapped back into the first text's
/// cosine units through that scale's linear form (`score = (z - b) / a`); `rank` then recovers the same z up to float
/// rounding. Words always come from the bare text: templates add no content words.
struct PhotoSearchVariant: FindVariant {
  let name: String
  let about: String
  let texts: @Sendable (ResolvedQuery) -> [String]

  func answer(_ query: ResolvedQuery, in library: FindLibrary) async throws -> VariantAnswer {
    let bare = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bare.isEmpty else { return VariantAnswer(strong: [], weaker: []) }
    let texts = self.texts(query)
    let rows = try texts.map { try library.scores($0) }
    let scales = rows.map { QueryScale(scores: $0) }  // == QueryScale(dots, query: 0)
    let reference = scales[0]

    // One text: the raw cosine. Several: the best z, in the first text's cosine units.
    var score = rows[0]
    var bestZ = rows[0].map(reference.z)
    if rows.count > 1 {
      for j in 1..<rows.count {
        for i in bestZ.indices { bestZ[i] = max(bestZ[i], scales[j].z(rows[j][i])) }
      }
      let (a, b) = reference.linear
      score = bestZ.map { ($0 - b) / a }
    }

    let terms = SearchTerms.queryTerms(bare)
    let coverage = terms.isEmpty ? [:] : try await library.repositories.keywordCoverage(terms: terms)
    var picked: [String: (score: Float, coverage: Double)] = [:]
    for row in 0..<library.ids.count where library.pooled[row] {
      let standsOut = bestZ[row] >= QueryScale.zGate
      guard standsOut || !coverage.isEmpty else { continue }
      let id = library.ids[row]
      let words = coverage[id] ?? 0
      if standsOut || words >= LibrarySearch.coverageGate { picked[id] = (score[row], words) }
    }
    let assets = try await library.repositories.searchAssets(ids: Array(picked.keys))
    let scored = assets.compactMap { asset in
      picked[asset.id].map { PhotoSearch.Scored(asset: asset, score: $0.score, coverage: $0.coverage) }
    }
    let result = PhotoSearch.rank(scored, scale: reference, compared: library.poolCount,
                                  lookup: SearchTerms.isLookup(terms), refinement: .init(), now: library.now)
    return VariantAnswer(result, notes: [
      "zTop": Double(bestZ.max() ?? 0),
      "cosTop": Double(rows.map { $0.max() ?? 0 }.max() ?? 0),
      "texts": Double(texts.count),
      "wordHits": Double(coverage.count),
    ])
  }
}
