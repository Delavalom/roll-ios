import Foundation
import Store

/// Describe-it search over the whole index ("screenshots of chats"): which photos match a sentence, which
/// match it less well, and what the answer adds up to. `SwipefileEngine.search` embeds the query, scores the
/// library in one `VectorStore.dotAll` and reads the words of screenshots and documents; `rank` is the pure part.
///
/// **What matches** (ADR-0005, retuned 2026-10-29 by the pile eval, `docs/investigations/2026-10-29-pile-eval.md`).
/// A photo qualifies if it stands out on this query's own scale over the whole library (`QueryScale`: z of its
/// cosine >= `QueryScale.zGate`), **or** its text holds at least `LibrarySearch.coverageGate` of the query's words
/// (names, codes, "uber receipt"; DigUp's idea). No absolute cosine floor: with this model every photo cleared the
/// old 0.2 floor for every query (cosines average 0.58-0.66), so it matched the whole library.
///
/// **Order and weaker matches.** Best first by `LibrarySearch.fusedScore` (z plus a word bonus; lookups such as
/// codes weigh words more). Qualified photos under `Fold.defaultRatio` x the best are returned as `weaker`, so the
/// answer can fold them ("6 weaker matches folded") rather than drop them.
///
/// A library too small or flat for a scale (`QueryScale.isDegenerate`) falls back to the 0.2 cosine floor.
public enum PhotoSearch {
  /// "Older than a year".
  public static let yearSeconds: Double = 365 * 86_400

  public struct Scored: Sendable, Equatable {
    public var asset: SearchAsset
    /// The query's cosine with the photo.
    public var score: Float
    /// Share of the query's words found in the photo's text (0 without text).
    public var coverage: Double
    public init(asset: SearchAsset, score: Float, coverage: Double = 0) {
      self.asset = asset; self.score = score; self.coverage = coverage
    }
  }

  /// Narrows an answer without asking again. The library statistics never change with it: a refinement
  /// filters what matched, it doesn't change what matching means.
  public struct Refinement: Sendable, Equatable, Hashable {
    /// Taken more than `yearSeconds` ago. Undated photos are left out: their age is unknown.
    public var olderThanAYear: Bool
    /// Largest first instead of best match first.
    public var biggestFirst: Bool
    /// Only photos whose original is on this iPhone (`SearchAsset.originalLocal == true`).
    public var onlyOnThisIPhone: Bool

    public init(olderThanAYear: Bool = false, biggestFirst: Bool = false, onlyOnThisIPhone: Bool = false) {
      self.olderThanAYear = olderThanAYear; self.biggestFirst = biggestFirst; self.onlyOnThisIPhone = onlyOnThisIPhone
    }

    public var isEmpty: Bool { !olderThanAYear && !biggestFirst && !onlyOnThisIPhone }
  }

  public struct Match: Sendable, Equatable, Identifiable {
    public var asset: SearchAsset
    /// `LibrarySearch.fusedScore`: the order of the answer.
    public var score: Float
    /// Share of the query's words found in the photo's text; > 0 means words helped find it.
    public var coverage: Double = 0
    public var id: String { asset.id }
    public var estBytes: Int64 { asset.estBytes }
    public var created: Double? { asset.created }
  }

  public struct Result: Sendable, Equatable {
    /// Best first, or largest first with `Refinement.biggestFirst`.
    public var matches: [Match] = []
    /// Qualified but well under the best; same order as `matches`.
    public var weaker: [Match] = []
    /// Estimated bytes of `matches`.
    public var totalBytes: Int64 = 0
    /// How many of `matches` are favorites.
    public var favorites: Int = 0
    /// Embedding the query plus scoring and ranking the library, measured by `SwipefileEngine.search`.
    public var elapsed: Duration = .zero
    /// How many photos were compared (the live, embedded library).
    public var compared: Int = 0

    public init() {}
  }

  /// Ranks `scored`. `scale` is the query's scale over the whole library and `compared` the library's size; both
  /// default to `scored` itself (all of the library scored). The engine passes the library's scale and only the
  /// photos worth reading (`SwipefileEngine.search`).
  public static func rank(_ scored: [Scored], scale: QueryScale? = nil, compared: Int? = nil, lookup: Bool = false,
                          refinement: Refinement, now: Double = Date().timeIntervalSince1970) -> Result {
    var result = Result()
    result.compared = compared ?? scored.count
    guard !scored.isEmpty else { return result }
    let scale = scale ?? QueryScale(scores: scored.map(\.score))
    let qualified = scored.compactMap { item -> (item: Scored, z: Float, fused: Float)? in
      let z = scale.z(item.score)
      guard z >= QueryScale.zGate || item.coverage >= LibrarySearch.coverageGate else { return nil }
      return (item, z, LibrarySearch.fusedScore(z: z, coverage: item.coverage, lookup: lookup))
    }
    guard let top = qualified.map(\.fused).max() else { return result }

    let cutoff = now - yearSeconds
    let kept = qualified.filter { entry in
      let asset = entry.item.asset
      if refinement.olderThanAYear, !(asset.created.map { $0 < cutoff } ?? false) { return false }
      if refinement.onlyOnThisIPhone, asset.originalLocal != true { return false }
      return true
    }
    let ordered = kept.sorted { a, b in
      if refinement.biggestFirst, a.item.asset.estBytes != b.item.asset.estBytes {
        return a.item.asset.estBytes > b.item.asset.estBytes
      }
      return a.fused != b.fused ? a.fused > b.fused : a.item.asset.id < b.item.asset.id
    }
    for entry in ordered {
      let match = Match(asset: entry.item.asset, score: entry.fused, coverage: entry.item.coverage)
      if Fold.isWeak(entry.fused, top: top) { result.weaker.append(match) } else { result.matches.append(match) }
    }
    result.totalBytes = result.matches.reduce(0) { $0 + $1.estBytes }
    result.favorites = result.matches.filter(\.asset.isFavorite).count
    return result
  }
}

/// The plain sentences an answer is built from. Derived from the matches only: nothing here is generated
/// or guessed.
public enum SearchSummary {
  /// A run of at most 3 consecutive half-years holding this share of the dated photos is "most".
  public static let mostShare = 0.6

  /// "Most are from 2023 and early 2024." for the shortest run of half-years (January to June is "early",
  /// July to December "late", both halves the bare year) holding at least `mostShare` of **all** the photos,
  /// dated or not; "All are from …" when it holds every one; otherwise "They span 2018 to 2026.". Nil when fewer
  /// than `mostShare` of them have a date: then nothing true can be said about "most".
  public static func when(_ dates: [Double?], calendar: Calendar = .current) -> String? {
    let halves = dates.compactMap { $0 }.map { seconds -> Int in
      let parts = calendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: seconds))
      return (parts.year ?? 0) * 2 + ((parts.month ?? 1) >= 7 ? 1 : 0)
    }
    let need = mostShare * Double(dates.count)
    guard let first = halves.min(), let last = halves.max(), Double(halves.count) >= need else { return nil }
    var counts: [Int: Int] = [:]
    for h in halves { counts[h, default: 0] += 1 }
    for length in 1...3 {
      var best: (start: Int, count: Int)? = nil
      for start in first...max(first, last - length + 1) {
        let count = (start..<start + length).reduce(0) { $0 + (counts[$1] ?? 0) }
        // Ties go to the most recent run.
        if best == nil || count >= best!.count { best = (start, count) }
      }
      if let best, Double(best.count) >= need {
        let lead = best.count == dates.count ? "All are from" : "Most are from"
        return "\(lead) \(phrase(Array(best.start..<best.start + length).filter { $0 <= last }))."
      }
    }
    return "They span \(first / 2) to \(last / 2)."
  }

  /// "none of them favorites", "1 is a favorite", "3 are favorites".
  public static func favorites(_ count: Int, of total: Int) -> String {
    switch count {
    case 0: total == 1 ? "not a favorite" : "none of them favorites"
    case 1: "1 is a favorite"
    default: "\(count) are favorites"
    }
  }

  /// Consecutive half-year keys (year × 2 + half) as "late 2022 and 2023".
  private static func phrase(_ halves: [Int]) -> String {
    var parts: [String] = []
    var i = 0
    while i < halves.count {
      let year = halves[i] / 2
      if halves[i] % 2 == 0, i + 1 < halves.count, halves[i + 1] == halves[i] + 1 {
        parts.append("\(year)"); i += 2
      } else {
        parts.append("\(halves[i] % 2 == 0 ? "early" : "late") \(year)"); i += 1
      }
    }
    return parts.joined(separator: " and ")
  }
}

/// Swipe review over a search answer: the matches, in the answer's order, minus anything decided in the
/// swipefile, deleted since, or already on screen. Swipes, undo and the "looks done" hint go to `engine`, so
/// they are stored and train the swipefile exactly as in any other pile.
public struct SearchDeck: SwipeDeck {
  private let matches: [PhotoSearch.Match]
  private let engine: any SwipeDeck
  private let repositories: Repositories

  public init(matches: [PhotoSearch.Match], engine: any SwipeDeck, repositories: Repositories) {
    self.matches = matches
    self.engine = engine
    self.repositories = repositories
  }

  public func candidates(for swipefile: SwipefileRecord, limit: Int, excluding: Set<String>) async throws
    -> [SwipefileEngine.Candidate] {
    guard try await repositories.swipefile(id: swipefile.id) != nil else {
      throw SwipefileEngine.EngineError.unknownSwipefile(swipefile.id)
    }
    guard limit > 0 else { return [] }
    let open = try await repositories.undecided(matches.map(\.id), in: swipefile.id)
    return matches.lazy
      .filter { open.contains($0.id) && !excluding.contains($0.id) }
      .prefix(limit)
      .map { SwipefileEngine.Candidate(id: $0.id, score: $0.score, estBytes: $0.estBytes, mediaType: $0.asset.mediaType) }
  }

  /// How many of the matches are still to swipe in `swipefile` (live, undecided).
  public func remaining(in swipefile: SwipefileRecord) async throws -> Int {
    try await repositories.undecided(matches.map(\.id), in: swipefile.id).count
  }

  @discardableResult
  public func record(swipefileId: String, assetId: String, verdict: Verdict) async throws -> Bool {
    try await engine.record(swipefileId: swipefileId, assetId: assetId, verdict: verdict)
  }

  public func undo(swipefileId: String, assetId: String) async throws {
    try await engine.undo(swipefileId: swipefileId, assetId: assetId)
  }

  public func isLikelyExhausted(swipefileId: String) async throws -> Bool {
    try await engine.isLikelyExhausted(swipefileId: swipefileId)
  }
}
