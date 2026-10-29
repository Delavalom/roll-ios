import Foundation
import Overview
import Store
import Testing

/// Feature prints and hashes from images well under 300 px link unrelated photos (the device re-run found 6,427 "similar"
/// extras from 120 px previews). Rows analysed from smaller images, or of unknown size, stay out of grouping.
struct GroupingSizeTests {
  static func shot(_ id: String, side: Int?) -> AssetRecord {
    var r = Make.asset(id, created: 1_000, bytes: 10, phash: Make.hashA, print: [1, 0, 0])
    r.previewSide = side
    return r
  }

  @Test func smallOrUnknownSizesAreLeftOutOfGroups() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("a", side: 300), Self.shot("b", side: 512), Self.shot("tiny", side: 120),
                                 Self.shot("unknown", side: nil)])
    let groups = try await CleanupScanner(repositories: repo).groups()
    #expect(groups.map { Set($0) } == [["a", "b"]])
  }

  /// The indexer asks for 300 px; a `.fast` resize can come back a pixel or two short. Those rows must still group,
  /// or most of the library would silently drop out of Duplicates.
  @Test func aFastResizeAFewPixelsShortStillGroups() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("a", side: 299), Self.shot("b", side: 298), Self.shot("tiny", side: 120)])
    let groups = try await CleanupScanner(repositories: repo).groups()
    #expect(groups.map { Set($0) } == [["a", "b"]])
  }

  @Test func theThresholds() {
    #expect(AssetRecord.minimumGroupingSide == 288, "4% under the 300 px request")
    #expect(Self.shot("x", side: 287).groupable == false && Self.shot("x", side: 288).groupable)
    #expect(Self.shot("x", side: 299).groupable)
    #expect(Self.shot("x", side: 255).qualityTrusted == false && Self.shot("x", side: 256).qualityTrusted)
    #expect(Self.shot("x", side: nil).qualityTrusted == false, "unknown size: not judged")
  }
}
