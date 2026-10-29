import Foundation
import Overview
import Ranking
import Signals
import Squish
import Store
import Testing

enum Make {
  static func asset(_ id: String, created: Double = 0, media: Int = Preset.imageMediaType, subtypes: Int = 0,
                    bytes: Int64 = 100, blur: Double? = 200, aesthetic: Double? = 0.5, phash: UInt64? = nil,
                    print: [Float]? = nil, favorite: Bool = false) -> AssetRecord {
    AssetRecord(id: id, mediaType: media, subtypes: subtypes, created: created, pixelW: 100, pixelH: 100,
                isFavorite: favorite, estBytes: bytes, signalsDone: true, blur: blur, aesthetic: aesthetic,
                phash: phash, featurePrint: print.map(FeaturePrints.encode(values:)), source: .full, previewSide: 300,
                originalLocal: true)
  }

  /// A 30 fps video of `seconds`, sized like `SizeEstimator` would (10 Mbps at 1080p, 45 Mbps at 4K).
  static func video(_ id: String, seconds: Double, w: Int = 1920, h: Int = 1080, subtypes: Int = 0,
                    phash: UInt64? = nil, created: Double = 0) -> AssetRecord {
    let bitrate: Double = min(w, h) >= 2160 ? 45_000_000 : 10_000_000
    return AssetRecord(id: id, mediaType: Preset.videoMediaType, subtypes: subtypes, created: created, pixelW: w,
                pixelH: h, duration: seconds, estBytes: Int64(seconds * bitrate / 8), signalsDone: true, blur: 200,
                aesthetic: 0.5, phash: phash, source: .full, previewSide: 300, originalLocal: true)
  }

  static let hashA: UInt64 = 0x5A5A_F0F0_3C3C_A5A5
  /// `hashA` with 2 bits flipped: a near-exact duplicate.
  static let hashA2: UInt64 = hashA ^ 0b101
  /// 20 bits away from `hashA`.
  static let hashB: UInt64 = hashA ^ 0xF_FFFF
}

struct CleanupSummaryTests {
  @Test func signalCategoriesSumTheirPresetFilters() {
    let records = [
      Make.asset("s1", subtypes: Preset.screenshotSubtype, bytes: 1_000),
      Make.asset("s2", subtypes: Preset.screenshotSubtype, bytes: 2_000),
      Make.asset("blurry", bytes: 300, blur: 10),
      Make.asset("ugly", bytes: 400, aesthetic: -0.5),
      Make.asset("fine", bytes: 9_999),
      Make.asset("bigVideo", media: Preset.videoMediaType, bytes: 60_000_000),
      Make.asset("smallVideo", media: Preset.videoMediaType, bytes: 50_000_000),
    ]
    let summary = CleanupSummary.make(records: records, groups: [])
    #expect(summary[.screenshots].plain == CategoryTotal(count: 2, bytes: 3_000))
    #expect(summary[.blurry].plain == CategoryTotal(count: 1, bytes: 300), "a low aesthetic score isn't blurry")
    #expect(summary[.bigVideos].plain == CategoryTotal(count: 1, bytes: 60_000_000))
    #expect(summary[.duplicates] == .zero)
    #expect(summary.library.plain == CategoryTotal(count: 7, bytes: records.reduce(0) { $0 + $1.estBytes }))
  }

  /// Blurry is photos only: a blurry video's count and bytes stay out of it, and out of what Home says it frees.
  @Test func blurryCountsPhotosOnly() {
    let records = [
      Make.asset("soft", bytes: 300, blur: 10),
      Make.asset("shakyVideo", media: Preset.videoMediaType, bytes: 40_000_000, blur: 3),
      Make.asset("lowScoreVideo", media: Preset.videoMediaType, bytes: 30_000_000, aesthetic: -0.9),
    ]
    let summary = CleanupSummary.make(records: records, groups: [])
    #expect(summary[.blurry].plain == CategoryTotal(count: 1, bytes: 300))
    #expect(summary.freeableBytes == 300)
  }

  /// The same through the Store, as Home scans it.
  @Test func scannerCountsBlurryPhotosOnly() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([
      Make.asset("soft", bytes: 300, blur: 10),
      Make.asset("shakyVideo", media: Preset.videoMediaType, bytes: 40_000_000, blur: 3),
      Make.asset("ugly", bytes: 500, aesthetic: -0.9),
    ])
    let summary = try await CleanupScanner(repositories: repo).scan()
    #expect(summary[.blurry].plain == CategoryTotal(count: 1, bytes: 300))
  }

  @Test func groupsCountEveryoneButTheKeeperAndSplitByHash() {
    let records = [
      // Exact trio: the favorite is kept.
      Make.asset("d1", created: 0, bytes: 10, phash: Make.hashA),
      Make.asset("d2", created: 1, bytes: 20, phash: Make.hashA2, favorite: true),
      Make.asset("d3", created: 2, bytes: 30, phash: Make.hashA),
      // Similar pair: one hash is far off, so it's "similar shots".
      Make.asset("m1", created: 100, bytes: 40, aesthetic: 0.9, phash: Make.hashA),
      Make.asset("m2", created: 101, bytes: 50, aesthetic: 0.1, phash: Make.hashB),
    ]
    let summary = CleanupSummary.make(records: records, groups: [["d1", "d2", "d3"], ["m1", "m2"]])
    #expect(summary.groups.count == 2)
    let exact = try! #require(summary.groups.first { $0.kind == .duplicates })
    #expect(exact.keeper == "d2")
    #expect(exact.members == ["d1", "d2", "d3"])
    #expect(exact.others == ["d1", "d3"])
    #expect(exact.reclaimableBytes == 40)
    let similar = try! #require(summary.groups.first { $0.kind == .similarShots })
    #expect(similar.keeper == "m1")
    #expect(summary[.duplicates].plain == CategoryTotal(count: 2, bytes: 40))
    #expect(summary[.similarShots].plain == CategoryTotal(count: 1, bytes: 50))
    #expect(summary.groups(.similarShots).map(\.id) == [similar.id])
  }

  @Test func groupWithoutHashesIsSimilarShots() {
    let records = [Make.asset("a", bytes: 5), Make.asset("b", bytes: 6)]
    let summary = CleanupSummary.make(records: records, groups: [["a", "b"]])
    #expect(summary.groups.first?.kind == .similarShots)
  }

  @Test func freeableCountsEachAssetOnceAndAVideoWithoutADurationSavesNothing() {
    let records = [
      // A screenshot that is also a duplicate non-keeper, and blurry: counted once.
      Make.asset("k", created: 0, subtypes: Preset.screenshotSubtype, bytes: 100, phash: Make.hashA, favorite: true),
      Make.asset("x", created: 1, subtypes: Preset.screenshotSubtype, bytes: 200, blur: 1, phash: Make.hashA),
      Make.asset("video", media: Preset.videoMediaType, bytes: 90_000_000),
    ]
    let summary = CleanupSummary.make(records: records, groups: [["k", "x"]])
    #expect(summary[.screenshots].bytes == 300)
    #expect(summary[.blurry].bytes == 200)
    #expect(summary[.duplicates].bytes == 200)
    #expect(summary.freeableBytes == 300)
  }

  @Test func freeableAddsBigVideosAtTheirSquishSavingsNotTheirFullSize() throws {
    let long = Make.video("long", seconds: 60)  // 75 MB at 10 Mbps
    let uhd = Make.video("uhd", seconds: 20, w: 3840, h: 2160)  // 4K: estimated at the 1080p cap
    let records = [
      Make.asset("shot", subtypes: Preset.screenshotSubtype, bytes: 1_000),
      long, uhd,
      // Slo-mo isn't squishable in v1: a big video that adds nothing.
      Make.video("slomo", seconds: 60, subtypes: SquishCandidates.videoHighFrameRate),
      // Copies Roll made (or remembered refusals) add nothing either.
      Make.video("copy", seconds: 60),
    ]
    let summary = CleanupSummary.make(records: records, groups: [], squishExcluding: ["copy"])
    let longSavings = try #require(SquishPlanner.offer(for: long, keep4K: false)).estimatedSavings
    let uhdSavings = try #require(SquishPlanner.offer(for: uhd, keep4K: false)).estimatedSavings
    #expect(longSavings > 0 && longSavings < long.estBytes)
    #expect(uhdSavings > 0 && uhdSavings < uhd.estBytes)
    // The card keeps the full size; the header gets the savings.
    #expect(summary[.bigVideos].plain == CategoryTotal(count: 4, bytes: long.estBytes + uhd.estBytes + 2 * 75_000_000))
    #expect(summary.bigVideoSavings == longSavings + uhdSavings)
    #expect(summary.freeableBytes == 1_000 + longSavings + uhdSavings)
  }

  @Test func aBigVideoThatIsAlsoADuplicateCountsOnceAtFullSize() throws {
    let keeper = Make.video("keeper", seconds: 60, phash: Make.hashA)
    let extra = Make.video("extra", seconds: 60, phash: Make.hashA, created: 1)
    let summary = CleanupSummary.make(records: [keeper, extra], groups: [["keeper", "extra"]])
    let deleted = try #require(summary.groups.first).others
    #expect(deleted.count == 1)
    let kept = deleted == ["extra"] ? keeper : extra
    let savings = try #require(SquishPlanner.offer(for: kept, keep4K: false)).estimatedSavings
    // The extra copy is deleted (full size); the keeper is squished (savings only).
    #expect(summary.bigVideoSavings == savings)
    #expect(summary.freeableBytes == 75_000_000 + savings)
  }

  @Test func unknownGroupMembersAreDropped() {
    let summary = CleanupSummary.make(records: [Make.asset("a")], groups: [["a", "gone"]])
    #expect(summary.groups.isEmpty)
  }

  @Test func queuedTotalsCountDistinctLiveAssets() {
    let records = [Make.asset("a", bytes: 10), Make.asset("b", bytes: 20)]
    let summary = CleanupSummary.make(records: records, groups: [], queuedAssetIds: ["a", "a", "b", "gone"],
                                      swipefileCount: 3)
    #expect(summary.queued.plain == CategoryTotal(count: 2, bytes: 30))
    #expect(summary.swipefileCount == 3)
  }
}

struct CleanupScannerTests {
  @Test func scanGroupsStoredPrintsAndSkipsDeletedRows() async throws {
    let database = try AppDatabase.inMemory()
    let repositories = Repositories(database)
    try await repositories.upsertAssets([
      Make.asset("p1", created: 1_000, bytes: 10, phash: Make.hashA, print: [1, 0, 0]),
      Make.asset("p2", created: 1_030, bytes: 20, phash: Make.hashB, print: [1, 0.1, 0]),
      Make.asset("far", created: 9_000, bytes: 30, phash: Make.hashB ^ 0xFF00_0000, print: [0, 0, 1]),
      Make.asset("gone", created: 1_010, subtypes: Preset.screenshotSubtype, bytes: 40, phash: Make.hashA,
                 print: [1, 0, 0]),
    ])
    try await repositories.markDeleted(["gone"])
    let swipefile = Preset.screenshots.swipefile(created: 1)
    try await repositories.save(swipefile)
    try await repositories.record(DecisionRecord(swipefileId: swipefile.id, assetId: "far", verdict: .action, decidedAt: 1))
    try await repositories.record(DecisionRecord(swipefileId: swipefile.id, assetId: "p1", verdict: .keep, decidedAt: 2))
    // The hidden queues (Duplicates, Similar shots, Squish) aren't the user's piles: Home doesn't count them.
    try await DuplicateReview.queue(DuplicateGroup(id: "p1", members: ["p1", "p2"], keeper: "p1", kind: .similarShots,
                                                   reclaimableBytes: 0), keeper: "p1", repositories: repositories)

    let summary = try await CleanupScanner(repositories: repositories).scan()
    #expect(summary.groups.map(\.members) == [["p1", "p2"]])
    #expect(summary[.screenshots] == .zero)
    #expect(summary.library.count == 3)
    #expect(summary.queued.plain == CategoryTotal(count: 1, bytes: 30))
    #expect(summary.swipefileCount == 1)
  }
}

struct CleanupScannerCachedGroupsTests {
  @Test func totalsReuseEarlierGroupsAndDropAssetsThatLeft() async throws {
    let repositories = Repositories(try AppDatabase.inMemory())
    try await repositories.upsertAssets([
      Make.asset("a", created: 1_000, bytes: 10, phash: Make.hashA, print: [1, 0, 0]),
      Make.asset("b", created: 1_001, bytes: 20, phash: Make.hashA, print: [1, 0, 0]),
      Make.asset("c", created: 1_002, bytes: 30, phash: Make.hashA, print: [1, 0, 0]),
    ])
    let scanner = CleanupScanner(repositories: repositories)
    let groups = try await scanner.groups()
    #expect(groups.map { Set($0) } == [["a", "b", "c"]])
    #expect(try await scanner.scan(groups: groups) == (try await scanner.scan()))

    try await repositories.markDeleted(["c"])
    let cached = try await scanner.scan(groups: groups)
    #expect(cached.groups.map { Set($0.members) } == [["a", "b"]], "the deleted member is dropped without regrouping")
    #expect(cached.library.count == 2)
    try await repositories.markDeleted(["b"])
    #expect(try await scanner.scan(groups: groups).groups.isEmpty, "a group of one is no group")
  }
}

struct CleanupScannerSquishTests {
  @Test func squishedCopiesAreNeverGroupedWithTheirOriginals() async throws {
    let repositories = Repositories(try AppDatabase.inMemory())
    try await repositories.upsertAssets([
      Make.asset("original", created: 1_000, bytes: 10, phash: Make.hashA, print: [1, 0, 0]),
      Make.asset("copy", created: 1_000, bytes: 5, phash: Make.hashA, print: [1, 0, 0]),
    ])
    #expect(try await CleanupScanner(repositories: repositories).scan().groups.count == 1)
    try await repositories.journalBegin(assetID: "original", originalBytes: 10, newBytes: 5)
    try await repositories.journalNoteNewAssetAsync(assetID: "original", newAssetID: "copy")
    #expect(try await CleanupScanner(repositories: repositories).scan().groups.isEmpty)
  }

  @Test func squishedCopiesAndOriginalsMidSquishAddNoSquishSavings() async throws {
    let repositories = Repositories(try AppDatabase.inMemory())
    try await repositories.upsertAssets([Make.video("original", seconds: 60), Make.video("copy", seconds: 60)])
    // Only videos whose format passed Squish's probe add savings.
    for id in ["original", "copy"] { try await repositories.recordVideoProbePassed(assetId: id) }
    let before = try await CleanupScanner(repositories: repositories).scan()
    try await repositories.journalBegin(assetID: "original", originalBytes: 10, newBytes: 5)
    try await repositories.journalNoteNewAssetAsync(assetID: "original", newAssetID: "copy")
    let after = try await CleanupScanner(repositories: repositories).scan()
    #expect(before.bigVideoSavings > 0)
    #expect(after.bigVideoSavings == 0, "the copy is Roll's; the original's squish isn't settled")
    try await repositories.journalSetState(assetID: "original", state: .committed, payload: nil)
    let settled = try await CleanupScanner(repositories: repositories).scan()
    #expect(settled.bigVideoSavings * 2 == before.bigVideoSavings, "only the original (still listed here) counts")
  }
}

extension CategoryTotal {
  /// Count and bytes only (`onDeviceBytes` has its own tests in HonestFreeableTests).
  var plain: CategoryTotal { CategoryTotal(count: count, bytes: bytes) }
}
