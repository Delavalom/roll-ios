import Testing
@testable import Signals

struct AestheticsTests {
  /// Skipped when the host does not expose the request. On this Mac (macOS 26) it runs.
  @Test(.enabled(if: Aesthetics.isSupported))
  func screenshotIsUtility() async throws {
    let result = try await Aesthetics.compute(try Fixtures.image("screenshot.png"))
    #expect(result.isUtility)
  }

  @Test(.enabled(if: Aesthetics.isSupported))
  func blurryScoresBelowItsSharpOriginal() async throws {
    let sharp = try await Aesthetics.compute(try Fixtures.image("sharp_b.jpg"))
    let blurry = try await Aesthetics.compute(try Fixtures.image("blurry_b.jpg"))
    #expect(blurry.overall < sharp.overall)  // measured -0.84 vs 0.65
    #expect(blurry.overall < -0.3)           // the Blurry preset's cutoff
  }
}
