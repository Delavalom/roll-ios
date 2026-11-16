import Foundation
@testable import Ranking
import Store
import Testing

private func answer(_ ids: [String], weaker: [String] = []) -> FindSearch.Result {
  func match(_ id: String) -> FindSearch.Match {
    FindSearch.Match(asset: SearchAsset(id: id, mediaType: 1, estBytes: 1, created: nil, isFavorite: false,
                                        originalLocal: nil),
                     score: 1, z: 3, coverage: 0, tagCoverage: 0, bonus: 0, eventId: nil)
  }
  var r = FindSearch.Result()
  r.matches = ids.map(match)
  r.weaker = weaker.map(match)
  return r
}

struct LivingAlbumTests {
  let saved = SavedSearchRecord(id: "s", query: "dog", albumName: "Dog", createdAt: 0, lastSeenRowid: 10)
  let rowids: [String: Int64] = ["old": 5, "edge": 10, "a": 11, "b": 12, "c": 13, "w": 14]

  @Test func offersOnlyNewUndecidedStrongMatchesInOrder() {
    let offer = LivingAlbum.newMatches(saved: saved, result: answer(["c", "old", "edge", "a", "b"], weaker: ["w"]),
                                       rowids: rowids, probabilities: nil, decided: ["b"], maxRowid: 20,
                                       firstUnembedded: nil)
    #expect(offer == LivingAlbum.Offer(ids: ["c", "a"], watermark: 20))
    let since = LivingAlbum.newMatches(saved: saved, since: 11, result: answer(["a", "c"]), rowids: rowids,
                                       probabilities: nil, decided: [], maxRowid: 20, firstUnembedded: nil)
    #expect(since.ids == ["c"])
  }

  @Test func thePilesClassifierFilters() {
    let offer = LivingAlbum.newMatches(saved: saved, result: answer(["a", "b", "c"]), rowids: rowids,
                                       probabilities: ["a": 0.9, "b": 0.2], decided: [], maxRowid: 20,
                                       firstUnembedded: nil)
    #expect(offer.ids == ["a"])  // c has no vector to judge
    let loose = LivingAlbum.newMatches(saved: saved, result: answer(["a", "b"]), rowids: rowids,
                                       probabilities: ["a": 0.9, "b": 0.2], decided: [], maxRowid: 20,
                                       firstUnembedded: nil, minimumProbability: 0.1)
    #expect(loose.ids == ["a", "b"])
  }

  @Test func theWatermarkWaitsForUnembeddedPhotosAndNeverMovesBack() {
    func mark(max: Int64, first: Int64?) -> Int64 {
      LivingAlbum.newMatches(saved: saved, result: answer([]), rowids: [:], probabilities: nil, decided: [],
                             maxRowid: max, firstUnembedded: first).watermark
    }
    #expect(mark(max: 20, first: 15) == 14)
    #expect(mark(max: 20, first: 11) == 10)
    #expect(mark(max: 20, first: nil) == 20)
    #expect(mark(max: 8, first: nil) == 10)  // rows deleted since: the watermark stays
    var refused = answer(["a"])
    refused.nothingFound = true
    #expect(LivingAlbum.newMatches(saved: saved, result: refused, rowids: rowids, probabilities: nil, decided: [],
                                   maxRowid: 20, firstUnembedded: nil).ids.isEmpty)
  }
}
