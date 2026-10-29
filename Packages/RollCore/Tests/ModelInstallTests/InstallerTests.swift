import Foundation
import Testing
@testable import ModelInstall

/// The install state machine over a fake transport (no network), the real Apple Archive extractor and a fake
/// activator.
struct InstallerTests {
  private let archiveName = "EmbeddingGemma2.aar"

  /// Pinned to the manifest `transport` serves (a build pins the published one), else to `Fixture.anyPin`.
  private func installer(_ model: PublishedModel? = nil, revision: String = Fixture.revisionA, root: URL,
                         transport: FakeTransport, extractor: any ArchiveExtractor = AppleArchiveExtractor(),
                         conditions: InstallConditions = .fixed()) -> ModelInstaller {
    ModelInstaller(model: model ?? Fixture.model(revision, manifestSHA256: transport.pin ?? Fixture.anyPin),
                   root: root, transport: transport, extractor: extractor, conditions: conditions)
  }

  private func publish(in dir: TempDir, required: Bool = true, payload: String = "weights") throws -> FakeTransport {
    let p = try Fixture.published(in: dir.url, required: required, payload: payload)
    return FakeTransport(["manifest.json": p.manifest, archiveName: p.archive])
  }

  private func root(_ dir: TempDir) -> URL { dir.url.appending(path: "RollModel") }
  private func store(_ dir: TempDir) -> URL { dir.url.appending(path: "PackageStore") }
  private func revisionFolder(_ dir: TempDir, _ revision: String = Fixture.revisionA) -> URL {
    root(dir).appending(path: "owner--model/\(revision)")
  }
  private func identity(_ revision: String = Fixture.revisionA) -> ModelIdentity {
    ModelIdentity(repo: "owner/model", revision: revision)
  }

  @Test func nothingIsDownloadedBeforeTheModelIsPublished() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let sut = installer(PublishedModel(repo: "owner/model", revision: "pending"), root: root(dir), transport: transport)
    await #expect(throws: ModelInstallError.notPublished) {
      try await sut.load(activator: FakeActivator()) { _ in }
    }
    #expect(transport.calls.isEmpty)
  }

  @Test func aCommitWithoutTheManifestPinIsNotPublishedEither() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let sut = installer(Fixture.model(manifestSHA256: nil), root: root(dir), transport: transport)
    await #expect(throws: ModelInstallError.notPublished) {
      try await sut.prepare(allowCellular: false) { _ in }
    }
    #expect(transport.calls.isEmpty)
  }

  @Test func aFreshInstallDownloadsVerifiesExtractsActivatesAndFreesTheSpace() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let sut = installer(root: root(dir), transport: transport)
    let activator = FakeActivator(), steps = Steps()

    let loaded = try await sut.load(activator: activator, report: steps.report)

    let folder = revisionFolder(dir)
    #expect(transport.calls.map(\.file) == ["manifest.json", archiveName])
    #expect(loaded == Activation(folder: folder.appending(path: "model"), identity: identity()))
    #expect(activator.activated == [loaded])
    #expect(activator.didActivateCount == 1)
    #expect(await sut.localState() == .installed(folder))
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(left == [".roll-model.json"])  // the extracted model is the activator's now
    #expect(!FileManager.default.fileExists(atPath: folder.path + ".partial"))
    let size = try #require(steps.all.compactMap { step -> Int64? in
      if case .downloading(_, let total) = step { total } else { nil }
    }.first)
    #expect(steps.all.contains(.downloading(completedBytes: size, totalBytes: size)))
    #expect(steps.all.suffix(2) == [.unpacking, .activating])
  }

  @Test func theNextLaunchActivatesWithoutTheNetwork() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let first = try await installer(root: root(dir), transport: transport)
      .load(activator: FakeActivator(store: store(dir))) { _ in }
    #expect(!FileManager.default.fileExists(atPath: first.folder.path))  // moved into the store, like the package
    let offline = FakeTransport()
    let activator = FakeActivator(store: store(dir))

    let again = try await installer(root: root(dir), transport: offline).load(activator: activator) { _ in }

    #expect(again == first)
    #expect(offline.calls.isEmpty)
    #expect(activator.activated == [first])
    #expect(await installer(root: root(dir), transport: offline).localState() == .installed(revisionFolder(dir)))
  }

  @Test func whenTheActivatorsInstallIsGoneTooTheModelIsDownloadedAgain() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let sut = installer(root: root(dir), transport: transport)
    _ = try await sut.load(activator: FakeActivator(store: store(dir))) { _ in }
    try FileManager.default.removeItem(at: store(dir))  // Roll's folder is already empty: nothing to adopt
    let activator = FakeActivator(store: store(dir))

    let loaded = try await sut.load(activator: activator) { _ in }

    #expect(activator.activated == [loaded, loaded])
    #expect(transport.calls(for: archiveName).count == 2)
    #expect(await sut.localState() == .installed(revisionFolder(dir)))
  }

  @Test func aManifestThatIsNotThePinnedOneIsRejectedBeforeTheArchive() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let pinned = Fixture.model(manifestSHA256: String(repeating: "e", count: 64))
    let sut = installer(pinned, root: root(dir), transport: transport)
    await #expect(throws: ModelInstallError.manifestMismatch) {
      try await sut.load(activator: FakeActivator()) { _ in }
    }
    #expect(transport.calls.map(\.file) == ["manifest.json"])
  }

  @Test func theRightPinPasses() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let p = try Fixture.published(in: dir.url)
    let transport = FakeTransport(["manifest.json": p.manifest, archiveName: p.archive])
    let sut = installer(Fixture.model(manifestSHA256: Checksum.sha256(data: p.manifest)), root: root(dir),
                        transport: transport)
    _ = try await sut.load(activator: FakeActivator()) { _ in }
  }

  @Test func aCorruptArchiveIsDeletedAndTheRetryReusesTheManifest() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let p = try Fixture.published(in: dir.url)
    let transport = FakeTransport(["manifest.json": p.manifest])
    var corrupt = p.archive
    corrupt[corrupt.count / 2] ^= 0xFF
    transport.serve(archiveName, corrupt)
    let sut = installer(root: root(dir), transport: transport)

    await #expect(throws: ModelInstallError.checksumMismatch(file: archiveName)) {
      try await sut.load(activator: FakeActivator()) { _ in }
    }
    #expect(await sut.localState() == .partial)
    let partial = root(dir).appending(path: "owner--model/\(Fixture.revisionA).partial")
    #expect(!FileManager.default.fileExists(atPath: partial.appending(path: "\(archiveName).download").path))

    transport.serve(archiveName, p.archive)
    _ = try await sut.load(activator: FakeActivator()) { _ in }
    #expect(transport.calls(for: "manifest.json").count == 1)
    #expect(transport.calls(for: archiveName).count == 2)
  }

  @Test func notEnoughSpaceStopsBeforeTheArchiveDownload() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(available: 10))
    await #expect(throws: ModelInstallError.self) {
      try await sut.load(activator: FakeActivator()) { _ in }
    }
    #expect(transport.calls.map(\.file) == ["manifest.json"])
    do {
      _ = try await sut.prepare(allowCellular: false) { _ in }
    } catch ModelInstallError.insufficientSpace(let required, let available) {
      #expect(available == 10)
      #expect(required > 10)
    }
  }

  @Test func offWiFiItSaysSoAndKeepsTheDownloadWiFiOnly() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    _ = try await sut.load(activator: FakeActivator(), report: steps.report)

    #expect(steps.all.first == .waiting(.wifi, totalBytes: nil))
    #expect(steps.all.contains { if case .waiting(.wifi, let total?) = $0 { total > 0 } else { false } })
    #expect(transport.calls.allSatisfy { !$0.allowCellular })
  }

  @Test func offWiFiTheLastStepBeforeTheTransferIsWaiting() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    transport.hang(archiveName)  // the background session holding the download until Wi-Fi
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    let waiting = Task { try await sut.prepare(allowCellular: false, report: steps.report) }
    while transport.calls(for: archiveName).isEmpty { try await Task.sleep(for: .milliseconds(5)) }

    guard case .waiting(.wifi, let total?) = steps.all.last else {
      Issue.record("expected waiting for Wi-Fi with the size, got \(steps.all)")
      return
    }
    #expect(total > 0)
    #expect(!steps.all.contains { if case .downloading = $0 { true } else { false } })
    waiting.cancel()
    _ = try? await waiting.value
  }

  @Test func offWiFiDownloadingIsReportedOnlyOnceBytesArrive() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    _ = try await sut.prepare(allowCellular: false, report: steps.report)

    #expect(!steps.all.contains(where: { if case .downloading(0, _) = $0 { true } else { false } }))
    let first = try #require(steps.all.firstIndex { if case .downloading = $0 { true } else { false } })
    #expect(first > 0)
    guard case .waiting(.wifi, _?) = steps.all[first - 1] else {
      Issue.record("expected waiting right before the first bytes, got \(steps.all)")
      return
    }
  }

  @Test func onWiFiDownloadingIsReportedAtOnce() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    transport.hang(archiveName)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport)

    let running = Task { try await sut.prepare(allowCellular: false, report: steps.report) }
    while transport.calls(for: archiveName).isEmpty { try await Task.sleep(for: .milliseconds(5)) }

    guard case .downloading(0, let total) = steps.all.last else {
      Issue.record("expected downloading from zero, got \(steps.all)")
      return
    }
    #expect(total > 0)
    running.cancel()
    _ = try? await running.value
  }

  @Test func lowDataModeOnWiFiWaitsLikeCellular() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    var lowData = NetworkPath.wifi
    lowData.isConstrained = true
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(lowData))

    _ = try await sut.load(activator: FakeActivator(), report: steps.report)

    #expect(steps.all.first == .waiting(.lowDataMode, totalBytes: nil))
    #expect(transport.calls.allSatisfy { !$0.allowCellular })
  }

  @Test func mobileDataWhenThePersonAllowsIt() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    _ = try await sut.load(allowCellular: true, activator: FakeActivator(), report: steps.report)

    #expect(!steps.all.contains { if case .waiting = $0 { true } else { false } })
    #expect(transport.calls.allSatisfy { $0.allowCellular })
  }

  @Test func anArchiveThatFinishedInTheBackgroundIsNotDownloadedAgain() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let p = try Fixture.published(in: dir.url)
    let partial = root(dir).appending(path: "owner--model/\(Fixture.revisionA).partial")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try p.manifest.write(to: partial.appending(path: "manifest.json"))
    try p.archive.write(to: partial.appending(path: "\(archiveName).download"))
    let transport = FakeTransport()
    let pinned = Fixture.model(manifestSHA256: Checksum.sha256(data: p.manifest))

    _ = try await installer(pinned, root: root(dir), transport: transport).load(activator: FakeActivator()) { _ in }

    #expect(transport.calls.isEmpty)
  }

  @Test func anArchiveThatFinishedInTheBackgroundStillNeedsTheSpaceToUnpack() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let p = try Fixture.published(in: dir.url)
    let partial = root(dir).appending(path: "owner--model/\(Fixture.revisionA).partial")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try p.manifest.write(to: partial.appending(path: "manifest.json"))
    try p.archive.write(to: partial.appending(path: "\(archiveName).download"))
    let transport = FakeTransport()
    let sut = installer(Fixture.model(manifestSHA256: Checksum.sha256(data: p.manifest)), root: root(dir),
                        transport: transport, conditions: .fixed(available: 10))

    await #expect(throws: ModelInstallError.self) { try await sut.prepare(allowCellular: false) { _ in } }
    #expect(transport.calls.isEmpty)
    #expect(await sut.localState() == .partial)
  }

  @Test func anArchiveWithoutTheTokenizerIsRefused() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir, required: false)
    let sut = installer(root: root(dir), transport: transport)
    await #expect(throws: ModelInstallError.badArchive("tokenizer/tokenizer.json is missing")) {
      try await sut.load(activator: FakeActivator()) { _ in }
    }
    #expect(await sut.localState() == .partial)
  }

  @Test func concurrentCallersShareOneDownload() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    transport.setDelay(.milliseconds(50))
    let sut = installer(root: root(dir), transport: transport)

    async let a = sut.prepare(allowCellular: false) { _ in }
    async let b = sut.prepare(allowCellular: false) { _ in }
    let (x, y) = try await (a, b)

    #expect(x == y)
    #expect(transport.calls(for: archiveName).count == 1)
  }

  @Test func allowingMobileDataRestartsAWiFiOnlyDownload() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    transport.hang(archiveName)
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    let waiting = Task { try await sut.prepare(allowCellular: false) { _ in } }
    while transport.calls(for: archiveName).isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    transport.hang(archiveName, false)
    let folder = try await sut.prepare(allowCellular: true) { _ in }

    #expect(await sut.localState() == .staged(folder))
    #expect(transport.calls(for: archiveName).map(\.allowCellular) == [false, true])
    await #expect(throws: CancellationError.self) { try await waiting.value }
  }

  @Test func aNewRevisionDownloadsWhileTheOldOneStaysInUseAndReplacesItLater() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let old = try await installer(revision: Fixture.revisionA, root: root(dir), transport: try publish(in: dir))
      .load(activator: FakeActivator(store: store(dir))) { _ in }
    let newTransport = try publish(in: dir, payload: "new weights")
    let sut = installer(revision: Fixture.revisionB, root: root(dir), transport: newTransport)
    let activator = FakeActivator(store: store(dir))

    // This launch: the old model, as its own revision (not the current one), and the new one staged in the background.
    let inUse = try await sut.load(activator: activator) { _ in }
    #expect(inUse == old)
    #expect(inUse.identity == identity(Fixture.revisionA))
    let staged = try await sut.prepare(allowCellular: false) { _ in }
    #expect(await sut.localState() == .staged(staged))
    #expect(FileManager.default.fileExists(atPath: revisionFolder(dir, Fixture.revisionA).path))
    #expect(activator.didActivateCount == 0)

    // A later launch: the new model, and the old folder is gone.
    let next = installer(revision: Fixture.revisionB, root: root(dir), transport: FakeTransport())
    let switched = try await next.load(activator: activator) { _ in }
    #expect(switched == Activation(folder: staged.appending(path: "model"), identity: identity(Fixture.revisionB)))
    #expect(!FileManager.default.fileExists(atPath: revisionFolder(dir, Fixture.revisionA).path))
    #expect(activator.didActivateCount == 1)
  }

  @Test func anInstalledFolderWhoseFilesAreGoneIsDownloadedAgain() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let sut = installer(root: root(dir), transport: transport)
    _ = try await sut.load(activator: FakeActivator()) { _ in }
    let activator = FakeActivator()
    activator.fail(with: ActivationError(redownload: true))

    let loaded = try await sut.load(activator: activator) { _ in }

    #expect(activator.activated == [loaded, loaded])
    #expect(transport.calls(for: archiveName).count == 2)
    #expect(await sut.localState() == .installed(revisionFolder(dir)))
  }

  @Test func aLoadFailureKeepsTheFolderAndDownloadsNothing() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let sut = installer(root: root(dir), transport: transport)
    let activator = FakeActivator()
    activator.fail(with: ActivationError(redownload: false))

    await #expect(throws: ActivationError(redownload: false)) { try await sut.load(activator: activator) { _ in } }
    guard case .staged(let folder) = await sut.localState() else { Issue.record("expected staged"); return }

    _ = try await sut.load(activator: activator) { _ in }  // the retry compiles again, without a download
    #expect(transport.calls(for: archiveName).count == 1)
    #expect(await sut.localState() == .installed(folder))
  }

  @Test func theRootIsExcludedFromBackups() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    _ = try await installer(root: root(dir), transport: try publish(in: dir)).load(activator: FakeActivator()) { _ in }
    let values = try root(dir).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }
  @Test func theArchiveIsExtractedFromTheFileThatWasVerifiedNotTheTransportsOne() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let p = try Fixture.published(in: dir.url)
    let transport = FakeTransport(["manifest.json": p.manifest, archiveName: p.archive])
    let expected = Checksum.sha256(data: p.archive)
    let seen = Steps()  // reused as a flag: one `.unpacking` per extraction that saw the right file
    let extractor = HookedExtractor { archive in
      let part = archive.appendingPathExtension("download")
      // What a late, stale transport callback could write: it must not be what gets extracted.
      try Data("stale".utf8).write(to: part)
      if archive.lastPathComponent == "EmbeddingGemma2.aar", try Checksum.sha256(file: archive) == expected {
        seen.report(.unpacking)
      }
    }
    let sut = installer(root: root(dir), transport: transport, extractor: extractor)

    _ = try await sut.prepare(allowCellular: false) { _ in }

    #expect(seen.all == [.unpacking])
  }

  @Test func aFullVolumeWhileUnpackingSaysHowMuchSpaceTheInstallNeeds() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let extractor = HookedExtractor { _ in throw ModelInstallError.insufficientSpace(required: 0, available: 0) }
    let sut = installer(root: root(dir), transport: transport, extractor: extractor,
                        conditions: .fixed(available: 1 << 40))
    let manifest = try ModelManifest.decode(try #require(transport.file("manifest.json")))

    await #expect(throws: ModelInstallError.insufficientSpace(
      required: InstallSpace.required(manifest, alreadyDownloaded: manifest.size), available: 1 << 40)) {
      try await sut.prepare(allowCellular: false) { _ in }
    }
    #expect(await sut.localState() == .partial)
  }
}
