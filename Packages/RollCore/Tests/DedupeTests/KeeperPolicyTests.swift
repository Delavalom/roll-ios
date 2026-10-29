import Foundation
import Testing
@testable import Dedupe
import Store

private func rec(_ id: String, created: Double = 0, fav: Bool = false, aesthetic: Double? = nil,
                 w: Int = 100, h: Int = 100) -> AssetRecord {
  AssetRecord(id: id, mediaType: 1, subtypes: 0, created: created, pixelW: w, pixelH: h,
              isFavorite: fav, aesthetic: aesthetic)
}

struct KeeperPolicyTests {
  @Test func favoriteBeatsEverything() {
    let group = [rec("best", fav: false, aesthetic: 0.99, w: 9000, h: 9000), rec("fav", fav: true, aesthetic: -1, w: 1, h: 1)]
    #expect(KeeperPolicy.keeper(group) == "fav")
  }

  @Test func higherAestheticBeatsSizeAndAge() {
    let group = [rec("big", created: 9, aesthetic: 0.2, w: 4000, h: 3000), rec("pretty", created: 1, aesthetic: 0.7)]
    #expect(KeeperPolicy.keeper(group) == "pretty")
  }

  @Test func scoredBeatsUnscored() {
    #expect(KeeperPolicy.keeper([rec("none", w: 4000, h: 3000), rec("neg", aesthetic: -0.5)]) == "neg")
  }

  @Test func largestPixelCountBreaksAestheticTie() {
    let group = [rec("small", created: 9, aesthetic: 0.5, w: 1000, h: 1000),
                 rec("large", created: 1, aesthetic: 0.5, w: 4000, h: 3000)]
    #expect(KeeperPolicy.keeper(group) == "large")
  }

  @Test func pixelCountNotWidth() {
    let group = [rec("wide", w: 5000, h: 100), rec("square", w: 1000, h: 1000)]
    #expect(KeeperPolicy.keeper(group) == "square")
  }

  @Test func newestBreaksRemainingTie() {
    let group = [rec("old", created: 1), rec("new", created: 99), rec("mid", created: 50)]
    #expect(KeeperPolicy.keeper(group) == "new")
  }

  @Test func fullTieFallsToSmallestIdRegardlessOfOrder() {
    #expect(KeeperPolicy.keeper([rec("b"), rec("a")]) == "a")
    #expect(KeeperPolicy.keeper([rec("a"), rec("b")]) == "a")
  }

  @Test func singleRecordIsItsOwnKeeper() {
    #expect(KeeperPolicy.keeper([rec("only")]) == "only")
  }

  @Test func multipleFavoritesFallThroughToAesthetic() {
    let group = [rec("f1", fav: true, aesthetic: 0.1), rec("f2", fav: true, aesthetic: 0.9), rec("n", aesthetic: 1.0)]
    #expect(KeeperPolicy.keeper(group) == "f2")
  }
}

struct KeeperPolicyNaNTests {
  @Test func nanAestheticCountsAsMissing() {
    let nan = AssetRecord(id: "nan", mediaType: 1, subtypes: 0, created: 5, pixelW: 100, pixelH: 100, aesthetic: .nan)
    let scored = AssetRecord(id: "scored", mediaType: 1, subtypes: 0, created: 1, pixelW: 10, pixelH: 10, aesthetic: -3)
    #expect(KeeperPolicy.keeper([nan, scored]) == "scored")
    #expect(KeeperPolicy.keeper([scored, nan]) == "scored")
  }

  @Test func nanVersusNilFallsThroughToSize() {
    let nan = AssetRecord(id: "nan", mediaType: 1, subtypes: 0, pixelW: 10, pixelH: 10, aesthetic: .nan)
    let nilScore = AssetRecord(id: "nil", mediaType: 1, subtypes: 0, pixelW: 20, pixelH: 20)
    #expect(KeeperPolicy.keeper([nan, nilScore]) == "nil")
    #expect(KeeperPolicy.keeper([nilScore, nan]) == "nil")
  }
}
