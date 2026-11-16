import Foundation
import Memories
@testable import Overview
import Store
import Testing

struct MemoryReelInputTests {
  func record(_ id: String, created: Double? = 100, mediaType: Int = 1, subtypes: Int = 0, utility: Bool? = false,
              aesthetic: Double? = nil, favorite: Bool = false, deleted: Bool = false) -> AssetRecord {
    AssetRecord(id: id, mediaType: mediaType, subtypes: subtypes, created: created, pixelW: 4000, pixelH: 3000,
                duration: mediaType == 2 ? 12 : nil, isFavorite: favorite, aesthetic: aesthetic, isUtility: utility,
                deleted: deleted)
  }

  @Test func mapsStoreFactsAndMarksOneKeeperPerLookAlikeGroup() {
    let records = [
      record("a", aesthetic: 0.2), record("b", aesthetic: 0.9, favorite: true), record("v", mediaType: 2),
      record("shot", subtypes: 1 << 2), record("doc", utility: true), record("undated", created: nil),
      record("gone", deleted: true), record("audio", mediaType: 3),
    ]
    let c = MemoryReelInput.candidates(records: records, groups: [["a", "b"]])
    #expect(c.map(\.id) == ["a", "b", "v", "shot", "doc"])
    let byId = Dictionary(uniqueKeysWithValues: c.map { ($0.id, $0) })
    #expect(byId["a"]?.similarGroup == byId["b"]?.similarGroup && byId["a"]?.similarGroup != nil)
    #expect(byId["b"]?.isKeeper == true && byId["a"]?.isKeeper == false, "the favorite is the group's keeper")
    #expect(byId["v"]?.isVideo == true && byId["v"]?.duration == 12)
    #expect(byId["v"]?.similarGroup == nil && byId["v"]?.isKeeper == true)
    #expect(byId["shot"]?.isScreenshotOrDocument == true && byId["doc"]?.isScreenshotOrDocument == true)
    #expect(byId["a"]?.created == Date(timeIntervalSince1970: 100))
    #expect(byId["a"]?.aesthetic == 0.2)
  }

  @Test func feedsThePlanner() {
    let records = (0..<10).map { record("p\($0)", created: Double($0) * 60, aesthetic: Double($0) / 10) }
    let plan = MemoryReelPlanner.plan(candidates: MemoryReelInput.candidates(records: records))
    #expect(plan.isUsable)
    #expect(MemoryReelPlanner.plan(candidates: MemoryReelInput.candidates(records: Array(records.prefix(2)))).problem
              != nil)
  }
}
