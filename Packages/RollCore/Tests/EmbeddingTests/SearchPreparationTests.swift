import Testing
@testable import Embedding

struct SearchPreparationTests {
  private let container = "/var/mobile/Containers/Data/Application/AAAA"

  private func marker(revision: String = "file-abc-b70", version: String? = "1.0", build: String? = "7",
                      container: String? = nil) -> String {
    SearchPreparation.marker(revision: revision, version: version, build: build, container: container ?? self.container)
  }

  @Test func theSameInstallKeepsItsMarker() {
    #expect(marker() == marker())
  }

  /// The 30k proof (2026-10-29): an install over the app with the same build moved the data container, so the Neural
  /// Engine cache key changed, but the marker matched and the first search compiled inline (52.5 s).
  @Test func aMovedContainerWithTheSameBuildPreparesAgain() {
    #expect(marker(container: "/var/mobile/Containers/Data/Application/BBBB") != marker())
  }

  @Test func aNewBuildOrVersionPreparesAgain() {
    #expect(marker(build: "8") != marker())
    #expect(marker(version: "1.1") != marker())
  }

  @Test func aNewModelRevisionPreparesAgain() {
    #expect(marker(revision: "file-def-b70") != marker())
    #expect(marker(revision: "file-abc-b280") != marker())
  }

  @Test func aMissingVersionOrBuildStillGivesAStableMarker() {
    #expect(marker(version: nil, build: nil) == marker(version: nil, build: nil))
    #expect(marker(version: nil, build: nil) != marker())
  }
}
