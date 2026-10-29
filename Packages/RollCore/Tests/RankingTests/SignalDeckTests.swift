import Foundation
import Ranking
import Store
import Synchronization
import Testing

/// Swipe review without the model: presets whose filter or ranking is a Vision/library signal.
struct SignalDeckTests {
  let repo: Repositories
  let deck: SignalDeck

  init() throws {
    repo = Repositories(try AppDatabase.inMemory())
    let clock = Mutex(0.0)
    deck = SignalDeck(repositories: repo, now: { clock.withLock { $0 += 1; return $0 } })
  }

  private func asset(_ id: String, media: Int = Preset.imageMediaType, subtypes: Int = 0, bytes: Int64 = 1_000,
                     blur: Double? = 200, aesthetic: Double? = 0.5) -> AssetRecord {
    AssetRecord(id: id, mediaType: media, subtypes: subtypes, created: 0, estBytes: bytes, signalsDone: true,
                blur: blur, aesthetic: aesthetic, previewSide: 300)
  }

  @Test func supportsOnlySignalRankedPresets() {
    #expect(SignalDeck.supports(Preset.screenshots.swipefile(created: 0)))
    #expect(SignalDeck.supports(Preset.blurry.swipefile(created: 0)))
    #expect(SignalDeck.supports(Preset.bigVideos.swipefile(created: 0)))
    #expect(!SignalDeck.supports(Preset.memes.swipefile(created: 0)))
    #expect(!SignalDeck.supports(Preset.privateStuff.swipefile(created: 0)))
    let custom = SwipefileRecord(id: "c", name: "c", kind: .custom, prompts: ["x"], action: .delete, created: 0)
    #expect(!SignalDeck.supports(custom))
  }

  @Test func screenshotsAreLargestFirstWithoutEmbeddings() async throws {
    let sf = Preset.screenshots.swipefile(created: 0)
    try await repo.save(sf)
    try await repo.upsertAssets([
      asset("small", subtypes: Preset.screenshotSubtype, bytes: 10),
      asset("big", subtypes: Preset.screenshotSubtype, bytes: 30),
      asset("mid", subtypes: Preset.screenshotSubtype, bytes: 20),
      asset("photo", bytes: 99),
    ])
    #expect(try await deck.candidates(for: sf, limit: 20, excluding: []).map(\.id) == ["big", "mid", "small"])
    #expect(try await deck.candidates(for: sf, limit: 2, excluding: ["big"]).map(\.id) == ["mid", "small"])
  }

  /// Blurry photos only, blurriest first: no low-aesthetic sharp shots, no videos.
  @Test func blurryRanksBlurryPhotosBlurriestFirst() async throws {
    let sf = Preset.blurry.swipefile(created: 0)
    try await repo.save(sf)
    try await repo.upsertAssets([
      asset("soft", blur: 20), asset("smeared", blur: 2), asset("ugly", blur: 300, aesthetic: -0.9), asset("sharp"),
      asset("shakyVideo", media: Preset.videoMediaType, bytes: 90_000_000, blur: 1),
    ])
    #expect(try await deck.candidates(for: sf, limit: 20, excluding: []).map(\.id) == ["smeared", "soft"])
  }

  /// The Blurry preset's filter gives the same pool in SQL (`rankingCandidates`) as in Swift (`candidateFilter`).
  @Test func blurryFilterAgreesInSQLAndSwift() async throws {
    let sf = Preset.blurry.swipefile(created: 0)
    try await repo.save(sf)
    var g = SystemRandomNumberGenerator()
    var records: [AssetRecord] = []
    for i in 0..<300 {
      var r = asset("a\(i)", media: Int.random(in: 1...3, using: &g),
                    blur: Bool.random(using: &g) ? nil : [0, 24.9, 25, 26].randomElement(using: &g)!,
                    aesthetic: Bool.random(using: &g) ? nil : [-1, -0.3, 0].randomElement(using: &g)!)
      r.previewSide = [nil, 100, 255, 256, 900].randomElement(using: &g)!
      records.append(r)
    }
    try await repo.upsertAssets(records)
    let sql = Set(try await repo.rankingCandidates(swipefileId: sf.id, embeddedOnly: false, filter: Preset.blurry.filter)
      .map(\.id))
    #expect(sql == Set(records.filter(Preset.blurry.candidateFilter).map(\.id)))
    #expect(!sql.isEmpty)
  }

  @Test func recordAndUndoMoveCardsInAndOutOfThePool() async throws {
    let sf = Preset.bigVideos.swipefile(created: 0)
    try await repo.save(sf)
    try await repo.upsertAssets([
      asset("v1", media: Preset.videoMediaType, bytes: 90_000_000),
      asset("v2", media: Preset.videoMediaType, bytes: 80_000_000),
    ])
    #expect(try await deck.record(swipefileId: sf.id, assetId: "v1", verdict: .action) == false)
    #expect(try await deck.candidates(for: sf, limit: 20, excluding: []).map(\.id) == ["v2"])
    #expect(try await repo.queued(for: sf.id).map(\.assetId) == ["v1"])
    try await deck.undo(swipefileId: sf.id, assetId: "v1")
    #expect(try await deck.candidates(for: sf, limit: 20, excluding: []).map(\.id) == ["v1", "v2"])
  }

  @Test func unsupportedOrUnknownSwipefilesThrow() async throws {
    let memes = Preset.memes.swipefile(created: 0)
    try await repo.save(memes)
    await #expect(throws: SignalDeck.DeckError.needsModel) {
      _ = try await deck.candidates(for: memes, limit: 5, excluding: [])
    }
    await #expect(throws: SwipefileEngine.EngineError.unknownSwipefile("preset.blurry")) {
      _ = try await deck.candidates(for: Preset.blurry.swipefile(created: 0), limit: 5, excluding: [])
    }
  }

  @Test func tenKeepsInARowLookDone() async throws {
    let sf = Preset.screenshots.swipefile(created: 0)
    try await repo.save(sf)
    try await repo.upsertAssets((0..<10).map { asset("s\($0)", subtypes: Preset.screenshotSubtype) })
    for i in 0..<9 { try await deck.record(swipefileId: sf.id, assetId: "s\(i)", verdict: .keep) }
    #expect(try await deck.isLikelyExhausted(swipefileId: sf.id) == false)
    try await deck.record(swipefileId: sf.id, assetId: "s9", verdict: .keep)
    #expect(try await deck.isLikelyExhausted(swipefileId: sf.id))
  }
}

struct CustomRecordTests {
  @Test func customRecordTrimsPromptsAndNeedsAPromptOrExample() throws {
    let record = try SwipefileEngine.customRecord(id: "c", name: "Tweets", prompts: ["  screenshots of tweets ", " "],
                                                  examples: [], action: .album, albumName: "Tweets", created: 5)
    #expect(record.prompts == ["screenshots of tweets"])
    #expect(record.kind == .custom && record.action == .album && record.albumName == "Tweets" && record.created == 5)
    #expect(throws: SwipefileEngine.EngineError.emptySwipefile) {
      try SwipefileEngine.customRecord(name: "x", prompts: ["  "], examples: [], action: .delete, created: 0)
    }
    #expect(try SwipefileEngine.customRecord(name: "x", prompts: [], examples: ["a"], action: .delete, created: 0)
      .examples == ["a"])
  }
}
