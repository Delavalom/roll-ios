import CoreGraphics
import Testing
@testable import Signals

struct SignalExtractorTests {
  struct Disabled: SensitivityAnalyzing {
    var isEnabled: Bool { false }
    func refreshPolicy() {}
    func isSensitive(_ image: CGImage) async throws -> Bool { true }
  }

  @Test func combinesEverySignalForARealPhoto() async throws {
    let image = try Fixtures.image("dup_a.jpg")
    let signals = try await SignalExtractor(analyzer: Disabled()).extract(image)
    #expect(signals.blur == BlurScore.score(image))
    #expect(signals.phash == PerceptualHash.dHash(image))
    let print = try #require(signals.featurePrint)
    #expect(try FeaturePrints.distance(print, print) == 0)
    #expect(signals.sensitive == nil)
    if Aesthetics.isSupported {
      #expect(signals.aesthetic != nil)
      #expect(signals.isUtility == false)
    }
  }

  @Test func screenshotIsFlaggedUtilityWhenSupported() async throws {
    guard Aesthetics.isSupported else { return }
    let signals = try await SignalExtractor(analyzer: Disabled()).extract(try Fixtures.image("screenshot.png"))
    #expect(signals.isUtility == true)
  }

  @Test func sensitiveFlagComesFromTheAnalyzer() async throws {
    struct Yes: SensitivityAnalyzing {
      var isEnabled: Bool { true }
      func refreshPolicy() {}
      func isSensitive(_ image: CGImage) async throws -> Bool { true }
    }
    let signals = try await SignalExtractor(analyzer: Yes()).extract(Fixtures.solid(width: 64, height: 64, gray: 90))
    #expect(signals.sensitive == true)
  }

  @Test func leavesFailedFieldsNil() async throws {
    // Too small to convolve: blur is nil, the rest is best effort.
    let signals = try await SignalExtractor(analyzer: Disabled()).extract(Fixtures.solid(width: 1, height: 1, gray: 0))
    #expect(signals.blur == nil)
    #expect(signals.phash == 0)
  }

  @Test func cancelledTaskThrowsInsteadOfReturningPartialSignals() async throws {
    let image = try Fixtures.image("dup_a.jpg")
    let extractor = SignalExtractor(analyzer: Disabled())
    let task = Task { () async throws -> AssetSignals in
      // Cancel ourselves before extracting: every stage must still end in CancellationError.
      withUnsafeCurrentTask { $0?.cancel() }
      return try await extractor.extract(image)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func refreshPolicyForwardsToTheAnalyzer() async throws {
    final class Counting: SensitivityAnalyzing, @unchecked Sendable {
      var refreshes = 0
      var isEnabled: Bool { false }
      func refreshPolicy() { refreshes += 1 }
      func isSensitive(_ image: CGImage) async throws -> Bool { true }
    }
    let counting = Counting()
    let extractor = SignalExtractor(analyzer: counting)
    extractor.refreshPolicy()
    _ = try await extractor.extract(Fixtures.solid(width: 16, height: 16, gray: 5))
    #expect(counting.refreshes == 1)  // extract never refreshes by itself
  }
}
