import CoreGraphics
import Embedding
import Foundation
import Ranking
import Store
import Synchronization
import Testing

/// Learning from swipes: when the classifier trains, exhaustion, undo, and rank-based trained piles.
struct SwipefileEngineTrainingTests {
  @Test func trainsAtEightDecisionsThenEveryFiveSwipes() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    // 4 positives (m*), 3 negatives (r*): 7 decisions, no training yet.
    let script: [(String, Verdict)] = [("m0", .action), ("r0", .keep), ("m1", .album), ("r1", .keep),
                                       ("m2", .action), ("r2", .keep), ("m3", .action)]
    for (id, verdict) in script {
      #expect(try await world.engine.record(swipefileId: sf.id, assetId: id, verdict: verdict) == false)
    }
    #expect(try await world.repo.swipefile(id: sf.id)?.classifier == nil)

    #expect(try await world.engine.record(swipefileId: sf.id, assetId: "r3", verdict: .keep) == true)
    let trained = try #require(try await world.repo.swipefile(id: sf.id))
    let firstBlob = try #require(trained.classifier)
    #expect(LogisticClassifier(blob: firstBlob, dimensions: 256) != nil)
    #expect(trained.swipesSinceTrain == 0)

    for i in 4..<8 {
      #expect(try await world.engine.record(swipefileId: sf.id, assetId: "r\(i)", verdict: .keep) == false)
    }
    #expect(try await world.repo.swipefile(id: sf.id)?.classifier == firstBlob)
    #expect(try await world.repo.swipefile(id: sf.id)?.swipesSinceTrain == 4)

    #expect(try await world.engine.record(swipefileId: sf.id, assetId: "m4", verdict: .action) == true)
    let retrained = try #require(try await world.repo.swipefile(id: sf.id))
    #expect(retrained.classifier != firstBlob && retrained.swipesSinceTrain == 0)
  }

  /// "Looks done": the user's last 10 swipes in this pile were all keep. Informational only.
  @Test func tenKeepsInARowLookExhausted() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    #expect(SwipefileEngine.exhaustionWindow == 10)
    #expect(try await world.engine.isLikelyExhausted(swipefileId: sf.id) == false)
    for i in 0..<9 { try await world.engine.record(swipefileId: sf.id, assetId: "r\(i)", verdict: .keep) }
    #expect(try await world.engine.isLikelyExhausted(swipefileId: sf.id) == false)
    try await world.engine.record(swipefileId: sf.id, assetId: "r9", verdict: .keep)
    #expect(try await world.engine.isLikelyExhausted(swipefileId: sf.id) == true)
    #expect(try await !world.engine.candidates(for: sf).isEmpty)  // never hides candidates

    try await world.engine.undo(swipefileId: sf.id, assetId: "r9")
    #expect(try await world.engine.isLikelyExhausted(swipefileId: sf.id) == false)
    try await world.engine.record(swipefileId: sf.id, assetId: "m0", verdict: .action)
    for i in 10..<19 { try await world.engine.record(swipefileId: sf.id, assetId: "r\(i)", verdict: .keep) }
    #expect(try await world.engine.isLikelyExhausted(swipefileId: sf.id) == false)  // m0 is in the last 10
    try await world.engine.record(swipefileId: sf.id, assetId: "r19", verdict: .keep)
    #expect(try await world.engine.isLikelyExhausted(swipefileId: sf.id) == true)
    #expect(try await world.engine.isLikelyExhausted(swipefileId: "nope") == false)
  }

  /// A swipe recorded while a retrain is in flight neither starts a second retrain nor gets
  /// wiped from the counter when the first one saves.
  @Test func retrainsDontOverlapAndKeepSwipesMadeMeanwhile() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    let script: [(String, Verdict)] = [("m0", .action), ("r0", .keep), ("m1", .album), ("r1", .keep),
                                       ("m2", .action), ("r2", .keep), ("m3", .action)]
    for (id, verdict) in script { try await world.engine.record(swipefileId: sf.id, assetId: id, verdict: verdict) }
    let gate = Gate()
    world.embedder.gate.withLock { $0 = gate }

    // The 8th swipe trains and blocks while embedding the prompt (cold cache).
    let first = Task { try await world.engine.record(swipefileId: sf.id, assetId: "r3", verdict: .keep) }
    await gate.wait { entered, _ in entered >= 1 }
    // The 9th: returns without training, or (if it overlapped) blocks in the gate as well.
    let second = Task {
      defer { Task { await gate.markDone() } }
      return try await world.engine.record(swipefileId: sf.id, assetId: "m4", verdict: .action)
    }
    await gate.wait { entered, done in done || entered >= 2 }
    await gate.open()

    #expect(try await first.value == true)
    #expect(try await second.value == false)
    #expect(await gate.entered == 1)
    let stored = try #require(try await world.repo.swipefile(id: sf.id))
    #expect(stored.classifier != nil && stored.swipesSinceTrain == 1)
  }

  /// Undoing a swipe the classifier was trained on: the next swipe retrains without it.
  @Test func undoAfterARetrainRetrainsOnTheNextSwipe() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    let script: [(String, Verdict)] = [("m0", .action), ("r0", .keep), ("m1", .album), ("r1", .keep),
                                       ("m2", .action), ("r2", .keep), ("m3", .action), ("r3", .keep)]
    for (id, verdict) in script { try await world.engine.record(swipefileId: sf.id, assetId: id, verdict: verdict) }
    let trained = try #require(try await world.repo.swipefile(id: sf.id)?.classifier)

    try await world.engine.undo(swipefileId: sf.id, assetId: "m3")
    #expect(try await world.engine.record(swipefileId: sf.id, assetId: "r4", verdict: .keep) == true)
    let stored = try #require(try await world.repo.swipefile(id: sf.id))
    #expect(stored.classifier != trained && stored.swipesSinceTrain == 0)
    #expect(try await !world.repo.decisions(for: sf.id).contains { $0.assetId == "m3" })
  }

  @Test func needsTwoOfEachLabelToTrain() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    for i in 0..<9 { try await world.engine.record(swipefileId: sf.id, assetId: "m\(i)", verdict: .action) }
    try await world.engine.record(swipefileId: sf.id, assetId: "r0", verdict: .keep)
    #expect(try await world.repo.swipefile(id: sf.id)?.classifier == nil)
    #expect(try await world.engine.record(swipefileId: sf.id, assetId: "r1", verdict: .keep) == true)
  }

  @Test func trainedRankingIsRankBasedAndFlagsLowConfidence() async throws {
    let (world, sf, matching) = try await memesWorld()
    defer { world.cleanUp() }
    for i in 0..<5 { try await world.engine.record(swipefileId: sf.id, assetId: "m\(i)", verdict: .action) }
    for i in 0..<5 { try await world.engine.record(swipefileId: sf.id, assetId: "r\(i)", verdict: .keep) }
    #expect(try await world.repo.swipefile(id: sf.id)?.classifier != nil)

    // The caller's copy is stale (no classifier): the engine reads the stored one.
    let top = try await world.engine.candidates(for: sf, limit: 100)
    #expect(top.count > 25)  // rank-based: far more than the matches above 0.5
    #expect(top.allSatisfy { $0.score >= SwipefileEngine.trainedProbabilityFloor && $0.score <= 1 })
    #expect(top.allSatisfy { $0.lowConfidence == ($0.score < SwipefileEngine.lowConfidenceBelow) })
    #expect(Set(top.prefix(20).map(\.id)).isSubset(of: matching))
    #expect(!top.contains { ["m0", "r0"].contains($0.id) })
    #expect(try await world.engine.candidates(for: sf, limit: 20).count == 20)
  }

  /// The reviewer's dead end: overlapping clusters and a pile where the user mostly keeps
  /// (2 positives, 18 keeps). The pile must not run dry while real matches remain, and the
  /// positives must lead it.
  @Test func imbalancedSwipesStillYieldTheMatchesFirst() async throws {
    let world = try await World.make()
    defer { world.cleanUp() }
    let sf = customPile(prompts: ["a funny meme"])
    try await world.repo.save(sf)
    let prompt = try await StubEmbedder().embed(query: "a funny meme")
    var g = SeededRNG(seed: 77)
    let other = randomUnit(256, using: &g)
    func noisy(_ c: [Float]) -> [Float] { unitVector(zip(c, randomUnit(256, using: &g)).map { $0 + 1.2 * $1 }) }
    var items: [(record: AssetRecord, vector: [Float]?)] = []
    for i in 0..<40 { items.append((photo("m\(i)"), noisy(prompt))) }
    for i in 0..<160 { items.append((photo("r\(i)"), noisy(other))) }
    try await world.add(items)

    try await world.engine.record(swipefileId: sf.id, assetId: "m0", verdict: .action)
    try await world.engine.record(swipefileId: sf.id, assetId: "m1", verdict: .album)
    for i in 0..<18 { try await world.engine.record(swipefileId: sf.id, assetId: "r\(i)", verdict: .keep) }

    // The stored classifier is the class-balanced fit (each class totals 0.5, the prompt 2x) of
    // the decisions at the last retrain: trainings ran at 8, 13 and 18 decisions.
    let blob = try #require(try await world.repo.swipefile(id: sf.id)?.classifier)
    let stored = try #require(LogisticClassifier(blob: blob, dimensions: 256))
    var x: [[Float]] = [], y: [Float] = []
    for d in try await world.repo.decisions(for: sf.id).prefix(18) {
      x.append(try #require(await world.vectors.vector(for: d.assetId))); y.append(d.verdict == .keep ? 0 : 1)
    }
    x.append(unitVector(prompt)); y.append(1)
    let expected = LogisticClassifier.train(
      x: x, y: y, weights: LogisticClassifier.classBalanced(y: y, weights: Array(repeating: 1, count: 18) + [2]))
    #expect(zip(stored.w, expected.w).allSatisfy { abs($0 - $1) < 1e-5 } && abs(stored.b - expected.b) < 1e-5)

    let top = try await world.engine.candidates(for: sf, limit: 20)
    #expect(top.count == 20)
    let hits = top.filter { $0.id.hasPrefix("m") }.count
    #expect(Double(hits) / 20 >= 0.8, "top-20 precision \(hits)/20")
    #expect(top.prefix(10).allSatisfy { $0.id.hasPrefix("m") })
    #expect(top.prefix(10).allSatisfy { !$0.lowConfidence })  // balanced weights: matches clear 0.5
  }

  /// Even when the classifier rates every asset under 0.5, the pile keeps dealing the best ones
  /// (flagged), instead of going empty with nothing left to retrain it.
  @Test func trainedPileNeverGoesEmptyWhileMatchesRemain() async throws {
    let (world, sf, matching) = try await memesWorld()
    defer { world.cleanUp() }
    let prompt = try await StubEmbedder().embed(query: "a funny meme")
    var stored = sf
    stored.classifier = LogisticClassifier(w: prompt.map { $0 * 4 }, b: -6).blob  // p <= sigmoid(-2)
    stored.classifierRevision = world.vectors.revision
    try await world.repo.save(stored)
    let top = try await world.engine.candidates(for: sf, limit: 20)
    #expect(top.count == 20)
    #expect(top.allSatisfy { $0.lowConfidence })
    #expect(Set(top.map(\.id)).isSubset(of: matching))
  }

  /// A classifier trained on another embedder revision is ignored (untrained scores) and replaced
  /// on the next swipe.
  @Test func classifierFromAnotherRevisionIsIgnored() async throws {
    let (world, sf, _) = try await memesWorld()
    defer { world.cleanUp() }
    let untrained = try await world.engine.candidates(for: sf, limit: 100)
    for i in 0..<5 { try await world.engine.record(swipefileId: sf.id, assetId: "m\(i)", verdict: .action) }
    for i in 0..<5 { try await world.engine.record(swipefileId: sf.id, assetId: "r\(i)", verdict: .keep) }
    var stored = try #require(try await world.repo.swipefile(id: sf.id))
    #expect(stored.classifier != nil && stored.classifierRevision == world.vectors.revision)

    stored.classifierRevision = "old-model"
    try await world.repo.save(stored)
    let decided = Set((0..<5).flatMap { ["m\($0)", "r\($0)"] })
    let now = try await world.engine.candidates(for: sf, limit: 100)
    #expect(now == untrained.filter { !decided.contains($0.id) })

    #expect(try await world.engine.record(swipefileId: sf.id, assetId: "m5", verdict: .action) == true)
    #expect(try await world.repo.swipefile(id: sf.id)?.classifierRevision == world.vectors.revision)
  }

}
