import Foundation
import Testing
@testable import ModelInstall

/// What the installer suites share: an installer over a fake transport (no network) and the real Apple Archive
/// extractor, the published fixture, and the folders it writes.
protocol InstallerTesting {}

extension InstallerTesting {
  var archiveName: String { "EmbeddingGemma2.aar" }

  /// Pinned to the manifest `transport` serves (a build pins the published one), else to `Fixture.anyPin`.
  func installer(_ model: PublishedModel? = nil, revision: String = Fixture.revisionA, root: URL,
                         transport: FakeTransport, extractor: any ArchiveExtractor = AppleArchiveExtractor(),
                         conditions: InstallConditions = .fixed()) -> ModelInstaller {
    ModelInstaller(model: model ?? Fixture.model(revision, manifestSHA256: transport.pin ?? Fixture.anyPin),
                   root: root, transport: transport, extractor: extractor, conditions: conditions)
  }

  func publish(in dir: TempDir, required: Bool = true, payload: String = "weights") throws -> FakeTransport {
    let p = try Fixture.published(in: dir.url, required: required, payload: payload)
    return FakeTransport(["manifest.json": p.manifest, archiveName: p.archive])
  }

  func root(_ dir: TempDir) -> URL { dir.url.appending(path: "RollModel") }
  func store(_ dir: TempDir) -> URL { dir.url.appending(path: "PackageStore") }
  func revisionFolder(_ dir: TempDir, _ revision: String = Fixture.revisionA) -> URL {
    root(dir).appending(path: "owner--model/\(revision)")
  }
  func identity(_ revision: String = Fixture.revisionA) -> ModelIdentity {
    ModelIdentity(repo: "owner/model", revision: revision)
  }
}
