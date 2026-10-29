import Testing
@testable import Signals

struct BlurScoreTests {
  @Test func blurryFixturesScoreUnderHalfOfTheirSharpOriginals() throws {
    for (sharp, blurry) in [("sharp_a.jpg", "blurry_a.jpg"), ("sharp_b.jpg", "blurry_b.jpg")] {
      let s = try #require(BlurScore.score(try Fixtures.image(sharp)))
      let b = try #require(BlurScore.score(try Fixtures.image(blurry)))
      #expect(b < 0.5 * s, "\(blurry)=\(b) vs \(sharp)=\(s)")
    }
  }

  @Test func measuredValuesSitFarFromAnyReasonableThreshold() throws {
    // Measured 2026-10-23 on the 448-px fixtures (0...255 scale): blurry 7.7 and 18.0, sharp 533 and 1218.
    for name in ["blurry_a.jpg", "blurry_b.jpg"] { #expect(try #require(BlurScore.score(try Fixtures.image(name))) < 50) }
    for name in ["sharp_a.jpg", "sharp_b.jpg", "dup_a.jpg"] { #expect(try #require(BlurScore.score(try Fixtures.image(name))) > 300) }
  }

  @Test func flatImageHasNoLaplacianResponse() throws {
    let score = try #require(BlurScore.score(Fixtures.solid(width: 300, height: 200, gray: 128)))
    #expect(score == 0)
  }

  @Test func imagesTooSmallToConvolveReturnNil() {
    #expect(BlurScore.score(Fixtures.solid(width: 2, height: 2, gray: 10)) == nil)
  }

  @Test func resultIsDeterministic() throws {
    let image = try Fixtures.image("sharp_a.jpg")
    #expect(BlurScore.score(image) == BlurScore.score(image))
  }
}
