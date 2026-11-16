import Foundation
import Store
import Testing

@testable import Ranking

/// The pieces that keep `find` fast: the running top-k for the nothing-found test and the asset read after ranking.
struct FindSpeedPartsTests {
  @Test func topFloatsKeepsTheLargestInOrder() {
    var g = SeededRNG(seed: 7)
    let values = (0..<5_000).map { _ in Float.random(in: -3...6, using: &g) }
    var top = TopFloats(count: 50)
    for v in values { top.insert(v) }
    #expect(top.descending == Array(values.sorted(by: >).prefix(50)))

    var few = TopFloats(count: 50)
    for v in [1, 3, 2] as [Float] { few.insert(v) }
    #expect(few.descending == [3, 2, 1])

    var none = TopFloats(count: 0)
    none.insert(1)
    #expect(none.descending.isEmpty)
  }

  @Test func replaceAssetsPatchesFavoritesAndDropsMissing() {
    func asset(_ id: String, favorite: Bool = false, bytes: Int64 = 10) -> SearchAsset {
      SearchAsset(id: id, mediaType: 1, estBytes: bytes, created: nil, isFavorite: favorite, originalLocal: nil)
    }
    func match(_ id: String) -> FindSearch.Match {
      FindSearch.Match(asset: asset(id), score: 1, z: 3, coverage: 0, tagCoverage: 0, bonus: 0, eventId: "m1")
    }
    var result = FindSearch.Result()
    result.matches = [match("a"), match("b"), match("gone")]
    result.weaker = [match("c")]
    result.sections = [
      FindSearch.Section(eventId: "m1", event: nil, matches: [match("a"), match("b")], score: 1),
      FindSearch.Section(eventId: "m2", event: nil, matches: [match("gone")], score: 1),
    ]
    FindSearch.replaceAssets(&result, with: [
      "a": asset("a", favorite: true, bytes: 100), "b": asset("b", bytes: 5), "c": asset("c"),
    ])
    #expect(result.matches.map(\.id) == ["a", "b"])
    #expect(result.weaker.map(\.id) == ["c"])
    #expect(result.sections.map(\.eventId) == ["m1"])
    #expect(result.sections[0].matches.first?.asset.isFavorite == true)
    #expect(result.favorites == 1)
    #expect(result.totalBytes == 105)
  }
}
