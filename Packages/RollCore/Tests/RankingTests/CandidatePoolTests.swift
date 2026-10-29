import Embedding
import Foundation
import Ranking
import Store
import Testing

/// The engine keeps the candidate rows in memory between searches. Whatever changes them must show up on the very
/// next call: decisions (from the engine or written elsewhere), deletions, newly embedded assets, changed signals or
/// library metadata, and vectors added or removed.
struct CandidatePoolTests {
  private struct World {
    let repo: Repositories
    let vectors: VectorStore
    let engine: SwipefileEngine
    let dir: URL
    let prompt: [Float]

    static func make() async throws -> World {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-pool-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let db = try AppDatabase.inMemory()
      let embedder = StubEmbedder()
      let vectors = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: embedder.dimensions,
                                          revision: embedder.revision, database: db)
      let repo = Repositories(db)
      let engine = SwipefileEngine(repositories: repo, vectors: vectors, embedder: embedder)
      let prompt = try await embedder.embed(query: Preset.screenshots.prompts[0])
      return World(repo: repo, vectors: vectors, engine: engine, dir: dir, prompt: prompt)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    /// Assets with vectors near the screenshots prompt (or exactly on it), in the commit order.
    func add(_ records: [AssetRecord], seed: UInt64 = 1) async throws {
      var g = SeededRNG(seed: seed)
      try await repo.upsertAssets(records)
      let batch = records.map { (id: $0.id, vector: unitVector(zip(prompt, randomUnit(prompt.count, using: &g))
        .map { $0 + 0.3 * $1 })) }
      try await vectors.upsert(batch)
      try await repo.markEmbedded(ids: records.map(\.id))
    }
  }

  private func photo(_ id: String, screenshot: Bool = false) -> AssetRecord {
    AssetRecord(id: id, mediaType: Preset.imageMediaType, subtypes: screenshot ? Preset.screenshotSubtype : 0,
                created: 0, estBytes: 1_000)
  }

  private func ids(_ world: World, _ sf: SwipefileRecord, limit: Int = 100) async throws -> Set<String> {
    Set(try await world.engine.candidates(for: sf, limit: limit).map(\.id))
  }

  private func screenshotsWorld() async throws -> (World, SwipefileRecord) {
    let world = try await World.make()
    let sf = Preset.screenshots.swipefile(created: 0)
    try await world.repo.save(sf)
    try await world.add((0..<6).map { photo("s\($0)", screenshot: true) } + [photo("p0")])
    return (world, sf)
  }

  @Test func aWarmSearchReadsNoRows() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    let cold = try await world.engine.timedCandidates(for: sf)
    let warm = try await world.engine.timedCandidates(for: sf)
    #expect(cold.timings.sql > .zero)
    #expect(warm.timings.sql == .zero)
    #expect(warm.cards == cold.cards)
    #expect(Set(cold.cards.map(\.id)) == Set((0..<6).map { "s\($0)" }))
  }

  /// The app can read the rows and align the presets' pools once the model is attached, so the first pile opened
  /// doesn't pay for the SQL read.
  @Test func preparedPoolsServeTheFirstSearchWithoutSQL() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    try await world.engine.preparePools(for: [.screenshots, .memes])
    let first = try await world.engine.timedCandidates(for: sf)
    #expect(first.timings.sql == .zero)
    #expect(first.cards.count == 6)
  }

  @Test func decisionsShowUpOnTheNextCall() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    _ = try await ids(world, sf)
    try await world.engine.record(swipefileId: sf.id, assetId: "s0", verdict: .keep)
    #expect(try await !ids(world, sf).contains("s0"))
    // Written outside the engine (a duplicate review, a commit): seen too.
    try await world.repo.record(DecisionRecord(swipefileId: sf.id, assetId: "s1", verdict: .action, decidedAt: 9))
    #expect(try await ids(world, sf) == ["s2", "s3", "s4", "s5"])
    try await world.engine.undo(swipefileId: sf.id, assetId: "s0")
    #expect(try await ids(world, sf).contains("s0"))
    // A decision in another pile doesn't hide the asset here.
    let other = Preset.memes.swipefile(created: 0)
    try await world.repo.save(other)
    try await world.engine.record(swipefileId: other.id, assetId: "s2", verdict: .keep)
    #expect(try await ids(world, sf).contains("s2"))
  }

  @Test func deletionsShowUpOnTheNextCall() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    _ = try await ids(world, sf)
    try await world.repo.markDeleted(["s3"])
    #expect(try await !ids(world, sf).contains("s3"))
    // The vector purge that follows (flag cleared, vector removed) keeps it out.
    _ = try await world.repo.clearEmbedded(ids: ["s3"])
    try await world.vectors.remove(id: "s3")
    #expect(try await !ids(world, sf).contains("s3"))
    #expect(try await ids(world, sf).count == 5)
  }

  @Test func newlyEmbeddedAssetsShowUpOnTheNextCall() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    _ = try await ids(world, sf)
    try await world.add([photo("s9", screenshot: true)], seed: 9)
    #expect(try await ids(world, sf).contains("s9"))

    // A vector saved but not flagged yet is not a candidate; the flag makes it one.
    try await world.repo.upsertAssets([photo("s10", screenshot: true)])
    try await world.vectors.upsert(id: "s10", vector: world.prompt)
    #expect(try await !ids(world, sf).contains("s10"))
    try await world.repo.markEmbedded(ids: ["s10"])
    #expect(try await world.engine.candidates(for: sf).first?.id == "s10")
  }

  @Test func changedMetadataShowsUpOnTheNextCall() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    #expect(try await !ids(world, sf).contains("p0"))
    try await world.repo.upsertAssets([photo("p0", screenshot: true)])  // the library now calls it a screenshot
    #expect(try await ids(world, sf).contains("p0"))
  }

  @Test func aFlaggedRowWithoutAVectorStaysOut() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    _ = try await ids(world, sf)
    try await world.vectors.remove(id: "s4")  // not reconciled yet: still flagged embedded
    #expect(try await !ids(world, sf).contains("s4"))
    try await world.vectors.upsert(id: "s4", vector: world.prompt)
    #expect(try await world.engine.candidates(for: sf).first?.id == "s4")
  }

  /// The pool caches each entry's row in the vector index as an integer. When a vector is removed and a new one takes
  /// its slot, every score must still belong to its own asset.
  @Test func scoresStayAlignedWhenSlotsAreReused() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    _ = try await ids(world, sf)
    _ = try await world.repo.clearEmbedded(ids: ["s1"])
    try await world.vectors.remove(id: "s1")
    try await world.add([photo("s7", screenshot: true), photo("s8", screenshot: true)], seed: 7)
    let cards = try await world.engine.candidates(for: sf, limit: 100)
    #expect(Set(cards.map(\.id)) == ["s0", "s2", "s3", "s4", "s5", "s7", "s8"])
    let scale = QueryScale(try await world.vectors.dotAll([world.prompt]), query: 0)
    for card in cards {
      let v = try #require(await world.vectors.vector(for: card.id))
      #expect(abs(card.score - scale.z(Scorer.cosine(v, world.prompt) + 1)) < 1e-3, "\(card.id)")
    }
  }

  /// The fast path typed search reuses: the pool of a pile (or of the whole library), aligned with the dot products.
  @Test func poolScoresExposeThePoolAndItsDots() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    try await world.repo.record(DecisionRecord(swipefileId: sf.id, assetId: "s0", verdict: .keep, decidedAt: 1))
    let q = [world.prompt, [1] + [Float](repeating: 0, count: world.prompt.count - 1)]
    let pile = try await world.engine.poolScores(queries: q, preset: .screenshots, filter: Preset.screenshots.filter,
                                                 decidedIn: sf.id, excluding: ["s5"])
    #expect(Set((0..<pile.count).map(pile.id)) == ["s0", "s1", "s2", "s3", "s4", "s5"])
    #expect(Set(pile.skipped.map(pile.id)) == ["s0", "s5"])  // decided, excluded
    let best = pile.top(pile.untrainedScores(promptCount: 1, hasCenter: false), limit: 10, minimum: 0)
    #expect(Set(best.map(pile.id)) == ["s1", "s2", "s3", "s4"])
    #expect(pile.dots.ids.count == 7)  // the whole index, e.g. for per-query statistics
    for k in 0..<pile.count {
      let v = try #require(await world.vectors.vector(for: pile.id(k)))
      #expect(abs(pile.dot(k, query: 0) - Scorer.cosine(v, q[0])) < 1e-3)
      #expect(abs(pile.dot(k, query: 1) - v[0]) < 1e-3)
      #expect(pile.boosts[k] == 1)
      #expect(pile.asset(k).id == pile.id(k))
    }
    let library = try await world.engine.poolScores(queries: q, preset: nil, filter: .none, decidedIn: nil, excluding: [])
    #expect(library.count == 7 && library.boosts.allSatisfy { $0 == 0 })
  }

  @Test func excludingStillApplies() async throws {
    let (world, sf) = try await screenshotsWorld()
    defer { world.cleanUp() }
    let all = try await ids(world, sf)
    let some = try await world.engine.candidates(for: sf, limit: 100, excluding: ["s0", "s5"])
    #expect(Set(some.map(\.id)) == all.subtracting(["s0", "s5"]))
  }
}
