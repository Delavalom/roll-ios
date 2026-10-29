import Embedding
import Foundation
import Store
import Testing
@testable import Ranking

private func item(_ id: String, _ score: Float, bytes: Int64 = 1_000, created: Double? = 0, favorite: Bool = false,
                  local: Bool? = true, coverage: Double = 0) -> PhotoSearch.Scored {
  PhotoSearch.Scored(asset: SearchAsset(id: id, mediaType: Preset.imageMediaType, estBytes: bytes, created: created,
                                        isFavorite: favorite, originalLocal: local), score: score, coverage: coverage)
}

/// A library of `noise` unrelated photos with cosines spread over 0.000..0.050.
private func background(_ noise: Int) -> [PhotoSearch.Scored] {
  (0..<noise).map { item("n\($0)", Float($0 % 11) / 200) }
}

private let utc: Calendar = {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "UTC")!
  return c
}()

private func date(_ year: Int, _ month: Int) -> Double {
  utc.date(from: DateComponents(year: year, month: month, day: 15))!.timeIntervalSince1970
}

struct PhotoSearchRankingTests {
  @Test func standoutsQualifyEvenUnderTheCosineFloor() {
    // Real text-to-image cosines are small: these sit under 0.2 but far above the library.
    let hits = (0..<5).map { item("h\($0)", 0.17 + Float($0) / 1_000) }
    let result = PhotoSearch.rank(background(200) + hits, refinement: .init())
    #expect(Set(result.matches.map(\.id)) == Set(hits.map(\.asset.id)))
    #expect(result.matches.map(\.score) == result.matches.map(\.score).sorted(by: >))
  }

  @Test func wordsQualifyWhatMeaningMisses() {
    // A receipt whose picture looks like the rest of the library but whose text holds the query's words.
    let receipt = item("receipt", 0.02, coverage: 1)
    let half = item("half", 0.02, coverage: 0.5)
    let few = item("few", 0.02, coverage: 0.3)
    let result = PhotoSearch.rank(background(200) + [receipt, half, few], refinement: .init())
    #expect(Set(result.matches.map(\.id) + result.weaker.map(\.id)) == ["receipt", "half"])
    #expect(result.matches.first?.id == "receipt")
    #expect(result.matches.first?.coverage == 1)
  }

  @Test func noCosineFloorOnARealScale() {
    // Every cosine is over the old 0.2 floor (as with EmbeddingGemma 2), yet only the standouts qualify.
    let library = (0..<300).map { item("n\($0)", 0.60 + Float($0 % 11) / 200) }
    let hits = (0..<3).map { item("h\($0)", 0.80) }
    let result = PhotoSearch.rank(library + hits, refinement: .init())
    #expect(Set(result.matches.map(\.id) + result.weaker.map(\.id)) == Set(hits.map(\.asset.id)))
  }

  @Test func nothingStandsOutInANoisyLibrary() {
    let result = PhotoSearch.rank(background(300), refinement: .init())
    #expect(result.matches.isEmpty)
    #expect(result.weaker.isEmpty)
  }

  @Test func weakerMatchesAreFoldedNotDropped() {
    // z: strong about 13, weak about 2.8: over the gate but under 0.4 x the best (Fold.defaultRatio).
    let strong = (0..<5).map { item("s\($0)", 0.60) }
    let weak = (0..<5).map { item("w\($0)", 0.15) }
    let result = PhotoSearch.rank(background(1_000) + strong + weak, refinement: .init())
    #expect(Set(result.matches.map(\.id)) == Set(strong.map(\.asset.id)))
    #expect(Set(result.weaker.map(\.id)) == Set(weak.map(\.asset.id)))
  }

  @Test func refinementsFilterTheMatchesAndBiggestFirstReorders() {
    let now = date(2026, 10)
    let hits = [
      item("old-big", 0.40, bytes: 9_000, created: date(2024, 3)),
      item("old-small-cloud", 0.41, bytes: 1_000, created: date(2024, 1), local: false),
      item("new", 0.42, bytes: 5_000, created: date(2026, 9)),
      item("undated", 0.43, bytes: 3_000, created: nil),
    ]
    let all = background(200) + hits

    let older = PhotoSearch.rank(all, refinement: .init(olderThanAYear: true), now: now)
    #expect(older.matches.map(\.id) == ["old-small-cloud", "old-big"])

    let local = PhotoSearch.rank(all, refinement: .init(olderThanAYear: true, onlyOnThisIPhone: true), now: now)
    #expect(local.matches.map(\.id) == ["old-big"])

    let biggest = PhotoSearch.rank(all, refinement: .init(biggestFirst: true), now: now)
    #expect(biggest.matches.map(\.id) == ["old-big", "new", "undated", "old-small-cloud"])
  }

  @Test func totalsCoverTheMatchesOnly() {
    let hits = [item("a", 0.4, bytes: 2_000, favorite: true), item("b", 0.4, bytes: 3_000)]
    let result = PhotoSearch.rank(background(100) + hits, refinement: .init())
    #expect(result.totalBytes == 5_000)
    #expect(result.favorites == 1)
  }

  @Test func tinyLibrariesOnlyMatchOverTheFloor() {
    // Three photos: a z-score means nothing, so only the cosine floor counts.
    let result = PhotoSearch.rank([item("a", 0.05), item("b", 0.06), item("c", 0.18)], refinement: .init())
    #expect(result.matches.isEmpty)
    #expect(result.compared == 3)
  }

  @Test func aNearlyFlatLibraryDoesNotFlood() {
    // 200 near-identical scores: the spread floor keeps a hair above the median from "standing out".
    let flat = (0..<200).map { item("f\($0)", 0.050 + Float($0 % 3) / 100_000) }
    #expect(PhotoSearch.rank(flat + [item("x", 0.053)], refinement: .init()).matches.isEmpty)
  }

  @Test func tinyLibrariesDoNotDivideByZero() {
    #expect(PhotoSearch.rank([], refinement: .init()).matches.isEmpty)
    let flat = PhotoSearch.rank((0..<5).map { item("f\($0)", 0.05) }, refinement: .init())
    #expect(flat.matches.isEmpty)
    let one = PhotoSearch.rank([item("x", 0.5)], refinement: .init())
    #expect(one.matches.map(\.id) == ["x"])
  }
}

struct SearchSummaryTests {
  @Test func mostAreFromARunOfHalfYears() {
    // 5 of 7 fall in 2023 H1 to 2024 H1; no two halves hold 60%.
    let dates = [date(2023, 2), date(2023, 5), date(2023, 8), date(2024, 3), date(2024, 4), date(2021, 6), date(2019, 6)]
    #expect(SearchSummary.when(dates, calendar: utc) == "Most are from 2023 and early 2024.")
  }

  @Test func phrasesEachShapeOfRun() {
    #expect(SearchSummary.when([date(2024, 2), date(2024, 4)], calendar: utc) == "All are from early 2024.")
    #expect(SearchSummary.when([date(2023, 9), date(2023, 12)], calendar: utc) == "All are from late 2023.")
    #expect(SearchSummary.when([date(2023, 2), date(2023, 9)], calendar: utc) == "All are from 2023.")
    #expect(SearchSummary.when([date(2023, 9), date(2024, 2)], calendar: utc) == "All are from late 2023 and early 2024.")
    #expect(SearchSummary.when([date(2022, 9), date(2023, 2), date(2023, 9), date(2019, 3)], calendar: utc)
      == "Most are from late 2022 and 2023.")
  }

  @Test func spreadOutDatesGiveTheSpan() {
    let dates = [date(2018, 3), date(2020, 3), date(2022, 3), date(2024, 3), date(2026, 3)]
    #expect(SearchSummary.when(dates, calendar: utc) == "They span 2018 to 2026.")
  }

  @Test func undatedMatchesCountAgainstMost() {
    // 2 of 10 dated: not "All are from 2023", and not "most" either.
    let dates: [Double?] = [date(2023, 2), date(2023, 3)] + Array(repeating: nil, count: 8)
    #expect(SearchSummary.when(dates, calendar: utc) == nil)
    // 7 of 10 dated, all in late 2023: most, not all.
    let most: [Double?] = Array(repeating: date(2023, 9), count: 7) + [nil, nil, nil]
    #expect(SearchSummary.when(most, calendar: utc) == "Most are from late 2023.")
  }

  @Test func noDatesNoSentence() {
    #expect(SearchSummary.when([nil, nil], calendar: utc) == nil)
    #expect(SearchSummary.when([], calendar: utc) == nil)
  }

  @Test func favorites() {
    #expect(SearchSummary.favorites(0, of: 22) == "none of them favorites")
    #expect(SearchSummary.favorites(0, of: 1) == "not a favorite")
    #expect(SearchSummary.favorites(1, of: 22) == "1 is a favorite")
    #expect(SearchSummary.favorites(3, of: 22) == "3 are favorites")
  }
}

/// `SwipefileEngine.search` and `SearchDeck` over a real store and index.
struct PhotoSearchEngineTests {
  private struct World {
    let repo: Repositories
    let vectors: VectorStore
    let engine: SwipefileEngine
    let dir: URL
    let matching: Set<String>

    /// m0..m29 sit near the query vector, r0..r269 are random (matches are 10 % of the index, so they stand out).
    static func make() async throws -> World {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-search-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let db = try AppDatabase.inMemory()
      let embedder = StubEmbedder()
      let vectors = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: embedder.dimensions,
                                          revision: embedder.revision, database: db)
      let repo = Repositories(db)
      let engine = SwipefileEngine(repositories: repo, vectors: vectors, embedder: embedder, now: { 1_000 })
      let query = try await embedder.embed(query: "screenshots of chats")
      var g = SeededRNG(seed: 7)
      var records: [AssetRecord] = []
      var embedded: [(id: String, vector: [Float])] = []
      for i in 0..<30 {
        records.append(AssetRecord(id: "m\(i)", mediaType: Preset.imageMediaType, subtypes: 0, created: 0,
                                   estBytes: Int64(1_000 + i)))
        embedded.append(("m\(i)", unitVector(zip(query, randomUnit(query.count, using: &g)).map { $0 + 0.45 * $1 })))
      }
      for i in 0..<270 {
        records.append(AssetRecord(id: "r\(i)", mediaType: Preset.imageMediaType, subtypes: 0, created: 0, estBytes: 1))
        embedded.append(("r\(i)", randomUnit(query.count, using: &g)))
      }
      try await repo.upsertAssets(records)
      try await vectors.upsert(embedded)
      try await repo.markEmbedded(ids: embedded.map(\.id))
      return World(repo: repo, vectors: vectors, engine: engine, dir: dir, matching: Set((0..<30).map { "m\($0)" }))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
  }

  @Test func searchFindsTheMatchingPhotosAndTimesItself() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let result = try await world.engine.search("screenshots of chats")
    #expect(Set(result.matches.map(\.id)) == world.matching)
    #expect(result.weaker.isEmpty)
    #expect(result.totalBytes == (0..<30).reduce(0) { $0 + Int64(1_000 + $1) })
    #expect(result.elapsed > .zero)
    #expect(result.compared == 300)
  }

  @Test func searchFindsPhotosByTheirWords() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let words = SwipefileEngine(repositories: world.repo, vectors: world.vectors, embedder: StubEmbedder(),
                                keywordCoverage: { terms in terms == ["uber", "receipt"] ? ["r5": 1, "r6": 0.4] : [:] },
                                now: { 1_000 })
    let result = try await words.search("uber receipt")
    let found = result.matches + result.weaker
    #expect(found.contains { $0.id == "r5" && $0.coverage == 1 })  // a random picture, found by its text
    #expect(!found.contains { $0.id == "r6" })  // under half the words
    #expect(result.compared == 300)
  }

  @Test func searchSkipsDeletedPhotosAndBlankQueries() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    try await world.repo.markDeleted(["m0", "m1"])
    let result = try await world.engine.search("screenshots of chats")
    #expect(Set(result.matches.map(\.id)) == world.matching.subtracting(["m0", "m1"]))
    #expect(try await world.engine.search("   ").matches.isEmpty)
  }

  @Test func searchDeckDealsTheResultsInOrderAndLearnsThroughTheEngine() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let result = try await world.engine.search("screenshots of chats", refinement: .init(biggestFirst: true))
    let sf = try await world.engine.createCustom(name: "Screenshots of chats", prompts: ["screenshots of chats"],
                                                 examples: [], action: .delete)
    let deck = SearchDeck(matches: result.matches, engine: world.engine, repositories: world.repo)
    let order = result.matches.map(\.id)
    #expect(order.first == "m29")

    let first = try await deck.candidates(for: sf, limit: 5, excluding: [])
    #expect(first.map(\.id) == Array(order.prefix(5)))
    #expect(first[0].estBytes == 1_029)

    try await deck.record(swipefileId: sf.id, assetId: order[0], verdict: .action)
    try await deck.record(swipefileId: sf.id, assetId: order[1], verdict: .keep)
    #expect(try await world.repo.decisions(for: sf.id).count == 2)
    let next = try await deck.candidates(for: sf, limit: 2, excluding: [order[2]])
    #expect(next.map(\.id) == [order[3], order[4]])

    try await deck.undo(swipefileId: sf.id, assetId: order[1])
    #expect(try await deck.candidates(for: sf, limit: 1, excluding: []).map(\.id) == [order[1]])

    try await world.repo.markDeleted([order[1]])
    #expect(try await deck.candidates(for: sf, limit: 1, excluding: []).map(\.id) == [order[2]])
    #expect(try await deck.isLikelyExhausted(swipefileId: sf.id) == false)
    #expect(try await deck.remaining(in: sf) == order.count - 2)  // order[0] decided, order[1] deleted

    try await world.repo.deleteSwipefile(id: sf.id)
    await #expect(throws: SwipefileEngine.EngineError.unknownSwipefile(sf.id)) {
      _ = try await deck.candidates(for: sf, limit: 1, excluding: [])
    }
  }
}
