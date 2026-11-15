import Embedding
import Foundation
@testable import Ranking
import Store
import Testing

/// `SwipefileEngine.find` end to end on a synthetic library: m0…m29 sit near the query "screenshots of chats"
/// (m0…m14 on one afternoon in June 2024, m15…m29 in June 2023), r0…r269 are random (2022, except r0…r4, which were
/// taken during m0…m14's afternoon).
private struct FindWorld {
  let repo: Repositories
  let vectors: VectorStore
  let engine: SwipefileEngine
  let dir: URL

  static let now = 1_794_744_000.0  // 2026-11-15
  static func june(_ year: Int, minute: Int) -> Double {
    var c = Calendar.current
    c.timeZone = .current
    return c.date(from: DateComponents(year: year, month: 6, day: 15, hour: 14, minute: minute))!.timeIntervalSince1970
  }

  static func make(keywordCoverage: LibrarySearch.KeywordCoverage? = nil) async throws -> FindWorld {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-find-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try AppDatabase.inMemory()
    let embedder = StubEmbedder()
    let vectors = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: embedder.dimensions,
                                        revision: embedder.revision, database: db)
    let repo = Repositories(db)
    let engine = SwipefileEngine(repositories: repo, vectors: vectors, embedder: embedder,
                                 keywordCoverage: keywordCoverage, now: { now })
    let query = try await embedder.embed(query: "screenshots of chats")
    var g = SeededRNG(seed: 7)
    var records: [AssetRecord] = []
    var embedded: [(id: String, vector: [Float])] = []
    for i in 0..<30 {
      let created = i < 15 ? june(2024, minute: i) : june(2023, minute: i)
      records.append(AssetRecord(id: "m\(i)", mediaType: Preset.imageMediaType, subtypes: 0, created: created,
                                 estBytes: Int64(1_000 + i)))
      embedded.append(("m\(i)", unitVector(zip(query, randomUnit(query.count, using: &g)).map { $0 + 0.45 * $1 })))
    }
    for i in 0..<270 {
      let created = i < 5 ? june(2024, minute: 20 + i) : june(2022, minute: 0) + Double(i) * 86_400
      records.append(AssetRecord(id: "r\(i)", mediaType: Preset.imageMediaType, subtypes: 0, created: created,
                                 estBytes: 1))
      embedded.append(("r\(i)", randomUnit(query.count, using: &g)))
    }
    try await repo.upsertAssets(records)
    try await vectors.upsert(embedded)
    try await repo.markEmbedded(ids: embedded.map(\.id))
    return FindWorld(repo: repo, vectors: vectors, engine: engine, dir: dir)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

private func ids(_ matches: [FindSearch.Match]) -> Set<String> { Set(matches.map(\.id)) }

struct FindEngineTests {
  @Test func searchIsFindWithTheDefaultConfig() async throws {
    let world = try await FindWorld.make(keywordCoverage: { _ in ["r9": 1, "r10": 0.4] })
    defer { world.cleanUp() }
    for refinement in [PhotoSearch.Refinement(), PhotoSearch.Refinement(olderThanAYear: true, biggestFirst: true)] {
      var old = try await world.engine.search("screenshots of chats", refinement: refinement)
      var new = try await world.engine.find("screenshots of chats", refinement: refinement).photoSearch
      old.elapsed = .zero
      new.elapsed = .zero
      #expect(old == new)
      #expect(new.matches.contains { $0.id == "r9" } || new.weaker.contains { $0.id == "r9" })
    }
    #expect(try await world.engine.find("   ").matches.isEmpty)
  }

  @Test func datesFilterTheAnswer() async throws {
    let world = try await FindWorld.make()
    defer { world.cleanUp() }
    let v0 = try await world.engine.find("screenshots of chats 2024")
    let r = try await world.engine.find("screenshots of chats 2024", config: .v2)
    #expect(r.understanding?.semanticText == "screenshots of chats")
    let found = ids(r.matches + r.weaker)
    #expect(Set((0..<15).map { "m\($0)" }).isSubset(of: found))
    #expect(!found.contains { ["m15", "m29", "r100"].contains($0) })
    #expect(!r.filterOnly && r.missingDate == 0)
    #expect(v0.understanding == nil)
  }

  @Test func filterOnlyQueriesReturnTheWholeWindowInEvents() async throws {
    let world = try await FindWorld.make()
    defer { world.cleanUp() }
    let pass = EventPass(repositories: world.repo, gazetteer: { nil })
    #expect(try await pass.run() != nil)
    let r = try await world.engine.find("photos 2024", config: .v2)
    #expect(r.filterOnly)
    let june2024 = Set((0..<15).map { "m\($0)" } + (0..<5).map { "r\($0)" })
    #expect(ids(r.matches) == june2024 && r.weaker.isEmpty)
    #expect(r.matches.map(\.id).first == "m0")  // by time
    #expect(r.sections.count == 1 && r.sections[0].event?.count == 20)
  }

  @Test func eventsGroupTheAnswerAndListTheRest() async throws {
    let world = try await FindWorld.make()
    defer { world.cleanUp() }
    #expect(try await EventPass(repositories: world.repo, gazetteer: { nil }).run() != nil)
    var config = FindConfig.v3
    config.expandRest = true
    let r = try await world.engine.find("screenshots of chats", config: config)
    let afternoon = try #require(r.sections.first { $0.matches.contains { $0.id == "m0" } })
    let shown = afternoon.matches.map(\.id)
    #expect(Set((0..<15).map { "m\($0)" }).isSubset(of: Set(shown)))
    // The rest is the afternoon's other photos, in time order (random ones the bonus didn't lift).
    #expect(afternoon.rest == (0..<5).map { "r\($0)" }.filter { !shown.contains($0) })
    #expect(Set(shown + afternoon.rest).count == 20)
  }

  @Test func seedsFindMoreLikeThem() async throws {
    let world = try await FindWorld.make()
    defer { world.cleanUp() }
    let plain = try await world.engine.find("zebra crossing at dusk")
    let seeded = try await world.engine.find("zebra crossing at dusk", config: .v5, seeds: ["m0", "m1", "m2"])
    let m = Set((0..<30).map { "m\($0)" })
    #expect(ids(plain.matches + plain.weaker).intersection(m).count < 10)
    #expect(ids(seeded.matches + seeded.weaker).intersection(m).count >= 20)
    #expect(ids(seeded.matches + seeded.weaker).subtracting(m).count < 5)
  }

  @Test func savedSearchesOfferWhatIsNewSinceTheirWatermark() async throws {
    let world = try await FindWorld.make()
    defer { world.cleanUp() }
    let rowids = try await world.repo.assetRowids(ids: ["m19", "r269"])
    let pile = SwipefileRecord(id: "sf", name: "Chats", kind: .custom, prompts: ["screenshots of chats"],
                               examples: [], action: .album, created: 0)
    try await world.repo.save(pile)
    try await world.engine.record(swipefileId: "sf", assetId: "m25", verdict: .keep)
    try await world.repo.save(SavedSearchRecord(id: "s", query: "screenshots of chats", albumName: "Chats",
                                                swipefileId: "sf", createdAt: 0, lastSeenRowid: rowids["m19"]!))
    try await world.repo.upsertAssets([AssetRecord(id: "late", mediaType: Preset.imageMediaType, subtypes: 0)])
    let offer = try #require(try await world.engine.newMatches(for: "s"))
    #expect(Set(offer.ids) == Set((20..<30).map { "m\($0)" }).subtracting(["m25"]))
    #expect(offer.watermark == rowids["r269"]!)  // "late" has no vector yet: it waits for the next run
    try await world.repo.markSavedSearchRun(id: "s", lastSeenRowid: offer.watermark, at: 1)
    #expect(try await world.engine.newMatches(for: "s")?.ids == [])
    #expect(try await world.engine.newMatches(for: "missing") == nil)
  }

  @Test func nothingFoundRefusesAFlatQuery() async throws {
    let world = try await FindWorld.make()
    defer { world.cleanUp() }
    var config = FindConfig()
    // Chance hits: best z 3.2 but only 2.2 above the 50th; the 30 real matches stand 3.0 above it.
    config.nothingFound = NothingFoundTest(minTopGap: 2.5, gapRank: 50)
    let nonsense = try await world.engine.find("zebra crossing at dusk", config: config)
    #expect(nonsense.nothingFound && nonsense.matches.isEmpty)
    let real = try await world.engine.find("screenshots of chats", config: config)
    #expect(!real.nothingFound && real.matches.count == 30)
  }
}
