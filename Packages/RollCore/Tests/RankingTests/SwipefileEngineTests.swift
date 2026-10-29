import CoreGraphics
import Embedding
import Foundation
import Ranking
import Store
import Synchronization
import Testing

struct SwipefileEngineTests {

  @Test func returnsTheBestMatchesAboveTheFloor() async throws {
    let (world, sf, matching) = try await memesWorld()
    defer { world.cleanUp() }
    let top = try await world.engine.candidates(for: sf)
    #expect(top.count == 20)
    #expect(Set(top.map(\.id)).isSubset(of: matching))
    #expect(top.map(\.score) == top.map(\.score).sorted(by: >))

    let all = try await world.engine.candidates(for: sf, limit: 100)
    #expect(Set(all.map(\.id)) == matching)  // random vectors don't stand out (z < zGate)
    #expect(all.allSatisfy { $0.score >= QueryScale.zGate })
  }

  /// Untrained scores are the prompt's z over the whole index: (cosine - mean) / deviation (`QueryScale`).
  /// "Weaker match" is judged against the best of the whole pile, decided cards included, so a card's label doesn't
  /// change as the strong ones are swiped away.
  @Test func weakerLabelsDontShiftAsCardsAreSwiped() async throws {
    // 3 copies of the prompt (z about 9.6), 10 moderate matches (cosine about 0.35, z 2.6-3.9: over the gate, most
    // under 0.4 x the best, so weaker), 600 random photos.
    let world = try await World.make()
    defer { world.cleanUp() }
    let sf = customPile(prompts: ["a funny meme"])
    try await world.repo.save(sf)
    let prompt = try await StubEmbedder().embed(query: "a funny meme")
    var g = SeededRNG(seed: 21)
    var items: [(record: AssetRecord, vector: [Float]?)] = (0..<3).map { (photo("top\($0)"), prompt) }
    for i in 0..<10 {
      items.append((photo("mid\(i)"), unitVector(zip(prompt, randomUnit(256, using: &g)).map { 0.35 * $0 + 0.94 * $1 })))
    }
    for i in 0..<600 { items.append((photo("r\(i)"), randomUnit(256, using: &g))) }
    try await world.add(items)

    let before = try await world.engine.candidates(for: sf, limit: 100)
    let labels = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.lowConfidence) })
    #expect(before.filter { $0.id.hasPrefix("mid") && $0.lowConfidence }.count >= 5)
    #expect(before.filter { $0.id.hasPrefix("top") }.allSatisfy { !$0.lowConfidence })
    for i in 0..<3 { try await world.engine.record(swipefileId: sf.id, assetId: "top\(i)", verdict: .keep) }
    let after = try await world.engine.candidates(for: sf, limit: 100)
    #expect(Set(after.map(\.id)) == Set(before.map(\.id).filter { $0.hasPrefix("mid") }))
    // Still judged against the pile's best, now decided: no weaker card turns into a normal match.
    for card in after { #expect(card.lowConfidence == labels[card.id], "\(card.id)") }
  }

  @Test func scoresAreThePromptsZOverTheIndex() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    let prompt = try await StubEmbedder().embed(query: "a funny meme")
    let scale = QueryScale(try await world.vectors.dotAll([prompt]), query: 0)
    #expect(!scale.isDegenerate)
    for c in try await world.engine.candidates(for: sf, limit: 5) {
      let v = try #require(await world.vectors.vector(for: c.id))
      #expect(abs(c.score - scale.z(Scorer.cosine(prompt, v))) < 1e-2)
    }
  }

  @Test func noRepeatsAfterADecision() async throws {
    let (world, sf, matching) = try await memesWorld()
    defer { world.cleanUp() }
    var seen = Set<String>()
    for _ in 0..<40 {
      guard let next = try await world.engine.candidates(for: sf).first else { break }
      #expect(!seen.contains(next.id))
      seen.insert(next.id)
      try await world.engine.record(swipefileId: sf.id, assetId: next.id, verdict: .keep)
    }
    #expect(seen == matching)  // every match seen exactly once, then nothing above the floor is left
  }

  /// The UI passes the cards already on screen, so a refill never deals them twice (a swipe can be
  /// in flight while the next batch is fetched).
  @Test func excludingSkipsTheVisibleStack() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    let first = try await world.engine.candidates(for: sf, limit: 5)
    let visible = Set(first.prefix(3).map(\.id))
    let next = try await world.engine.candidates(for: sf, limit: 5, excluding: visible)
    #expect(next.count == 5 && visible.isDisjoint(with: next.map(\.id)))
    #expect(next.prefix(2).map(\.id) == first.suffix(2).map(\.id))

    let videos = Preset.bigVideos.swipefile(created: 0)
    try await world.repo.save(videos)
    try await world.add([(photo("v1", mediaType: Preset.videoMediaType, bytes: 90_000_000), nil),
                         (photo("v2", mediaType: Preset.videoMediaType, bytes: 80_000_000), nil)])
    #expect(try await world.engine.candidates(for: videos, excluding: ["v1"]).map(\.id) == ["v2"])
  }

  @Test func undoRemovesTheDecision() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    let first = try #require(try await world.engine.candidates(for: sf).first)
    try await world.engine.record(swipefileId: sf.id, assetId: first.id, verdict: .action)
    #expect(try await world.repo.decisions(for: sf.id).map(\.assetId) == [first.id])
    #expect(try await !world.engine.candidates(for: sf, limit: 100).contains { $0.id == first.id })

    try await world.engine.undo(swipefileId: sf.id, assetId: first.id)
    #expect(try await world.repo.decisions(for: sf.id).isEmpty)
    #expect(try await world.repo.swipefile(id: sf.id)?.swipesSinceTrain == 0)
    #expect(try await world.engine.candidates(for: sf).first?.id == first.id)
  }

  @Test func skipsDeletedUnembeddedAndFilteredAssets() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let memes = Preset.memes.swipefile(created: 0)
    try await world.repo.save(memes)
    let prompt = try await StubEmbedder().embed(query: Preset.memes.prompts[0])
    try await world.add([
      (photo("ok"), prompt),
      (photo("gone"), prompt),
      (photo("video", mediaType: Preset.videoMediaType), prompt),
      (photo("pending"), nil),
    ])
    try await world.repo.markDeleted(["gone"])
    #expect(try await world.engine.candidates(for: memes).map(\.id) == ["ok"])
  }

  /// A row flagged embedded whose vector is missing from the index (not reconciled yet) has no
  /// score: it must not ride in on its signal boost alone.
  @Test func assetsMissingFromTheIndexAreNotCandidates() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let shots = Preset.screenshots.swipefile(created: 0)
    try await world.repo.save(shots)
    var g = SeededRNG(seed: 12)
    let shot = { (id: String) in AssetRecord(id: id, mediaType: Preset.imageMediaType, subtypes: Preset.screenshotSubtype) }
    try await world.add([(shot("real"), randomUnit(256, using: &g))])
    try await world.repo.upsertAssets([shot("ghost")])
    try await world.repo.markEmbedded(ids: ["ghost"])  // flag without a vector
    #expect(try await world.engine.candidates(for: shots, limit: 10).map(\.id) == ["real"])
  }

  @Test func examplesPullTheirNeighbors() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    var g = SeededRNG(seed: 9)
    let center = randomUnit(256, using: &g)
    var items: [(record: AssetRecord, vector: [Float]?)] = [(photo("ex"), center)]
    for i in 0..<10 { items.append((photo("n\(i)"), near(center, using: &g))) }
    for i in 0..<140 { items.append((photo("r\(i)"), randomUnit(256, using: &g))) }
    try await world.add(items)
    let sf = customPile(prompts: [], examples: ["ex"])
    try await world.repo.save(sf)
    let ids = Set(try await world.engine.candidates(for: sf, limit: 100).map(\.id))
    #expect(ids == Set(["ex"] + (0..<10).map { "n\($0)" }))  // 11 of 151 stand out on the mean example's scale; randoms don't
  }

  @Test func bigVideosRankByBytesWithoutEmbeddings() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let sf = Preset.bigVideos.swipefile(created: 0)
    try await world.repo.save(sf)
    let mb: Int64 = 1_000_000
    var g = SeededRNG(seed: 4)
    try await world.add([
      (photo("v80", mediaType: Preset.videoMediaType, bytes: 80 * mb), nil),
      (photo("v300", mediaType: Preset.videoMediaType, bytes: 300 * mb), nil),
      (photo("v120", mediaType: Preset.videoMediaType, bytes: 120 * mb), randomUnit(256, using: &g)),
      (photo("v10", mediaType: Preset.videoMediaType, bytes: 10 * mb), nil),
      (photo("img", mediaType: Preset.imageMediaType, bytes: 900 * mb), nil),
    ])
    #expect(try await world.engine.candidates(for: sf).map(\.id) == ["v300", "v120", "v80"])
    #expect(try await world.engine.candidates(for: sf).first?.estBytes == 300 * mb)
    try await world.engine.record(swipefileId: sf.id, assetId: "v300", verdict: .action)
    #expect(try await world.engine.candidates(for: sf, limit: 1).map(\.id) == ["v120"])
    #expect(world.embedder.calls.withLock { $0 } == 0)
  }

  @Test func promptVectorsAreCachedUntilThePromptsChange() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    _ = try await world.engine.candidates(for: sf)
    _ = try await world.engine.candidates(for: sf)
    #expect(world.embedder.calls.withLock { $0 } == 1)
    var edited = sf
    edited.prompts = ["a funny meme", "a reaction image"]
    try await world.repo.save(edited)
    _ = try await world.engine.candidates(for: edited)
    #expect(world.embedder.calls.withLock { $0 } == 3)
  }

  /// Prompt vectors from another model revision live in a different space than the index.
  @Test func embedderRevisionMustMatchTheIndex() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    let other = SwipefileEngine(repositories: world.repo, vectors: world.vectors, embedder: StubEmbedder(seed: 99))
    await #expect(throws: SwipefileEngine.EngineError.revisionMismatch) {
      _ = try await other.candidates(for: sf)
    }

    // A warm prompt cache doesn't bypass the check.
    _ = try await world.engine.candidates(for: sf)
    world.embedder.revisionOverride.withLock { $0 = "another-model" }
    await #expect(throws: SwipefileEngine.EngineError.revisionMismatch) {
      _ = try await world.engine.candidates(for: sf)
    }
  }

  /// The caller's copy is not a fallback: a deleted swipefile has no candidates to show.
  @Test func deletedSwipefileThrowsOnCandidates() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    try await world.repo.deleteSwipefile(id: sf.id)
    await #expect(throws: SwipefileEngine.EngineError.unknownSwipefile(sf.id)) {
      _ = try await world.engine.candidates(for: sf)
    }
  }

  /// A custom swipefile with nothing to rank by would never deal a card.
  @Test func customSwipefileNeedsAPromptOrAnExample() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    await #expect(throws: SwipefileEngine.EngineError.emptySwipefile) {
      _ = try await world.engine.createCustom(name: "Nothing", prompts: [], examples: [], action: .delete)
    }
    await #expect(throws: SwipefileEngine.EngineError.emptySwipefile) {
      _ = try await world.engine.createCustom(name: "Blank", prompts: ["  ", ""], examples: [], action: .delete)
    }
    #expect(try await world.repo.swipefiles().isEmpty)

    let cats = try await world.engine.createCustom(name: "Cats", prompts: [" a cat ", ""], examples: [], action: .delete)
    #expect(cats.kind == .custom && cats.prompts == ["a cat"] && cats.preset == nil)
    let byExample = try await world.engine.createCustom(name: "Like this", prompts: [], examples: ["a1"],
                                                        action: .album, albumName: "Keep")
    #expect(byExample.examples == ["a1"] && byExample.albumName == "Keep")
    #expect(try await Set(world.repo.swipefiles().map(\.id)) == [cats.id, byExample.id])
  }

  @Test func unknownSwipefileThrowsOnRecord() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    await #expect(throws: SwipefileEngine.EngineError.unknownSwipefile("nope")) {
      try await world.engine.record(swipefileId: "nope", assetId: "a", verdict: .keep)
    }
  }

  /// 50k embedded assets, a 3-prompt preset: under 150 ms per call in release (debug gets a sanity bound).
  @Test func candidatesOverFiftyThousandAssetsStayFast() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let memes = Preset.memes.swipefile(created: 0)
    try await world.repo.save(memes)
    var g = SeededRNG(seed: 50)
    let n = 50_000
    await world.vectors.reserve(n)
    var items: [(record: AssetRecord, vector: [Float]?)] = []
    items.reserveCapacity(n)
    for i in 0..<n { items.append((photo("a\(i)"), randomUnit(256, using: &g))) }
    try await world.add(items)
    for i in 0..<10 { try await world.engine.record(swipefileId: memes.id, assetId: "a\(i)", verdict: .keep) }

    _ = try await world.engine.candidates(for: memes)  // warm the prompt cache
    var best = Duration.seconds(100)
    for _ in 0..<3 {
      let start = ContinuousClock.now
      let top = try await world.engine.candidates(for: memes)
      best = min(best, ContinuousClock.now - start)
      #expect(top.count <= 20)
    }
    print("RANKING-PERF candidates 50k untrained (3 prompts): \(best)")

    var sf = try #require(try await world.repo.swipefile(id: memes.id))
    sf.classifier = LogisticClassifier(w: randomUnit(256, using: &g), b: 0).blob
    sf.classifierRevision = world.vectors.revision
    try await world.repo.save(sf)
    var bestTrained = Duration.seconds(100)
    for _ in 0..<3 {
      let start = ContinuousClock.now
      _ = try await world.engine.candidates(for: sf)
      bestTrained = min(bestTrained, ContinuousClock.now - start)
    }
    print("RANKING-PERF candidates 50k trained: \(bestTrained)")
    #if DEBUG
    #expect(best < .seconds(10) && bestTrained < .seconds(10))
    #else
    #expect(best < .milliseconds(150) && bestTrained < .milliseconds(150))
    #endif
  }
}
