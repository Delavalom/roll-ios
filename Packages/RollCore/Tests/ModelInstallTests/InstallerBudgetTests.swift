import Foundation
import Testing
@testable import ModelInstall

/// Each image budget's package has its own manifest (b70/, b280/): the installer accepts this phone's and refuses
/// the other's.
struct InstallerBudgetTests: InstallerTesting {
  @Test func aFreshInstallOnThe280BudgetAcceptsItsOwnManifest() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let p = try Fixture.published(in: dir.url, budget: 280)
    let transport = FakeTransport(["manifest.json": p.manifest, archiveName: p.archive])
    let sut = installer(Fixture.model(manifestSHA256: transport.pin, budget: 280), root: root(dir), transport: transport)
    _ = try await sut.load(activator: FakeActivator()) { _ in }
    #expect(transport.calls.map(\.file) == ["manifest.json", archiveName])
  }

  /// The other budget's manifest (a wrong pin aside) is refused before the archive is fetched.
  @Test func anotherBudgetsManifestIsRefused() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let p = try Fixture.published(in: dir.url, budget: 280)
    let transport = FakeTransport(["manifest.json": p.manifest, archiveName: p.archive])
    let sut = installer(Fixture.model(manifestSHA256: transport.pin, budget: 70), root: root(dir), transport: transport)
    await #expect(throws: ModelInstallError.invalidManifest("image budget 280, not 70")) {
      try await sut.load(activator: FakeActivator()) { _ in }
    }
    #expect(transport.calls.map(\.file) == ["manifest.json"])
  }
}
