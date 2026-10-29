import CoreGraphics
import Testing
@testable import Signals

struct SensitiveTests {
  struct FakeAnalyzer: SensitivityAnalyzing {
    var isEnabled: Bool
    var answer: Result<Bool, any Error>
    func refreshPolicy() {}
    func isSensitive(_ image: CGImage) async throws -> Bool { try answer.get() }
  }
  struct Boom: Error {}

  let image = Fixtures.solid(width: 8, height: 8, gray: 0)

  @Test func disabledPolicyIsNil() async {
    #expect(await Sensitive.check(image, analyzer: FakeAnalyzer(isEnabled: false, answer: .success(true))) == nil)
  }

  @Test func enabledPolicyReportsTheAnswer() async {
    #expect(await Sensitive.check(image, analyzer: FakeAnalyzer(isEnabled: true, answer: .success(true))) == true)
    #expect(await Sensitive.check(image, analyzer: FakeAnalyzer(isEnabled: true, answer: .success(false))) == false)
  }

  @Test func analysisFailureIsNilNotFalse() async {
    #expect(await Sensitive.check(image, analyzer: FakeAnalyzer(isEnabled: true, answer: .failure(Boom()))) == nil)
  }

  @Test func systemAnalyzerIsNilWhenThePolicyIsDisabled() async {
    // The test host has no entitlement, so the policy is normally .disabled; when a developer has
    // turned it on, there is no nil path to assert here.
    let system = SystemSensitivityAnalyzer()
    if !system.isEnabled { #expect(await Sensitive.check(image, analyzer: system) == nil) }
  }
}
