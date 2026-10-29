import Foundation
import Testing
@testable import ModelInstall

struct ManifestTests {
  private let sha = String(repeating: "0123456789abcdef", count: 4)

  @Test func decodesTheMinimalManifest() throws {
    let m = try ModelManifest.decode(Fixture.manifestJSON(size: 366_000_000, sha256: sha))
    #expect(m == ModelManifest(archive: "EmbeddingGemma2.aar", size: 366_000_000, sha256: sha))
    #expect(m.unpackedSize == nil && m.label == nil && m.functions == nil)
  }

  @Test func readsTheOptionalFieldsAndIgnoresUnknownOnes() throws {
    let json = """
      {"format": 1, "archive": "m.aar", "size": 10, "sha256": "\(sha)", "unpacked_size": 14, "revision": "v1.0.0",
       "functions": \(ModelManifest.requiredFunctions.sorted()), "publisher_note": {"anything": true}}
      """
    let m = try ModelManifest.decode(Data(json.utf8))
    #expect(m.unpackedSize == 14)
    #expect(m.label == "v1.0.0")
    #expect(Set(m.functions ?? []) == ModelManifest.requiredFunctions)
  }

  @Test(arguments: ["../m.aar", "dir/m.aar", "/m.aar", ".m.aar", "", "manifest.json", "m.aar.download",
                    "m.aar.resume", "..", "unpacked", "Unpacked", "Manifest.JSON"])
  func rejectsArchiveNamesThatAreNotOnePlainFile(_ name: String) {
    #expect(throws: ModelInstallError.self) {
      try ModelManifest.decode(Fixture.manifestJSON(archive: name, size: 10, sha256: sha))
    }
  }

  @Test(arguments: [String(repeating: "A", count: 64), "abc", String(repeating: "g", count: 64)])
  func rejectsHashesThatAreNotLowercaseSHA256(_ hash: String) {
    #expect(throws: ModelInstallError.self) { try ModelManifest.decode(Fixture.manifestJSON(size: 10, sha256: hash)) }
  }

  @Test func rejectsAnEmptyArchive() {
    #expect(throws: ModelInstallError.self) { try ModelManifest.decode(Fixture.manifestJSON(size: 0, sha256: sha)) }
  }

  @Test(arguments: [Int64(-1), 0, ModelManifest.maxBytes + 1, Int64.max])
  func rejectsANegativeOrAbsurdUnpackedSize(_ unpacked: Int64) {
    #expect(throws: ModelInstallError.self) {
      try ModelManifest.decode(Fixture.manifestJSON(size: 10, sha256: sha, unpackedSize: unpacked))
    }
  }

  @Test(arguments: [ModelManifest.maxBytes + 1, Int64.max])
  func rejectsAnAbsurdArchiveSize(_ size: Int64) {
    #expect(throws: ModelInstallError.self) { try ModelManifest.decode(Fixture.manifestJSON(size: size, sha256: sha)) }
  }

  @Test func theLargestSizesStillAddUpWithoutOverflow() throws {
    let max = ModelManifest.maxBytes
    let m = try ModelManifest.decode(Fixture.manifestJSON(size: max, sha256: sha, unpackedSize: max))
    #expect(m.unpackedSize == max)
    #expect(InstallSpace.required(m, alreadyDownloaded: 0) == 3 * max)
  }

  @Test func rejectsANewerFormat() {
    let json = #"{"format": 2, "archive": "m.aar", "size": 10, "sha256": "\#(sha)"}"#
    #expect(throws: ModelInstallError.invalidManifest("format 2 is newer than this app")) {
      try ModelManifest.decode(Data(json.utf8))
    }
  }

  @Test func rejectsAFunctionListWithoutWhatRollLoads() {
    let fns = ModelManifest.requiredFunctions.subtracting(["embed_image_280_wide"]).sorted()
    let json = #"{"archive": "m.aar", "size": 10, "sha256": "\#(sha)", "functions": \#(fns)}"#
    #expect(throws: ModelInstallError.invalidManifest("missing functions embed_image_280_wide")) {
      try ModelManifest.decode(Data(json.utf8))
    }
  }

  @Test func rejectsMalformedJSON() {
    #expect(throws: ModelInstallError.self) { try ModelManifest.decode(Data("[]".utf8)) }
    #expect(throws: ModelInstallError.self) { try ModelManifest.decode(Data(#"{"archive": "m.aar"}"#.utf8)) }
  }

  @Test func requiredFunctionsAreTheFourTextLengthsAndTenImageBuckets() {
    #expect(ModelManifest.requiredFunctions.count == 14)
    #expect(ModelManifest.requiredFunctions.contains("embed_text_128"))
    #expect(ModelManifest.requiredFunctions.contains("embed_image_70_tall"))
  }
}

struct PublishedModelTests {
  @Test func thisBuildPinsV1() {
    // embeddinggemma-coreml v1.0.0 (s7): delavalom/embeddinggemma-2-coreml at 8036f0b, both budgets pinned.
    #expect(PublishedModel.current(budget: 70).isPublished)
    #expect(PublishedModel.current(budget: 280).isPublished)
    #expect(PublishedModel.current(budget: 70).baseURL.absoluteString
      == "https://huggingface.co/delavalom/embeddinggemma-2-coreml/resolve/8036f0bbba34dad5093108601ac6d060c63bbe76/b70/")
  }

  @Test func onlyBudgets70And280ArePublished() {
    let pin = String(repeating: "c", count: 64)
    #expect(PublishedModel(repo: "owner/model", revision: Fixture.revisionA, budget: 280, manifestSHA256: pin).isPublished)
    #expect(!PublishedModel(repo: "owner/model", revision: Fixture.revisionA, budget: 140, manifestSHA256: pin).isPublished)
  }

  @Test func aRepoCommitAndManifestPinArePublished() {
    #expect(Fixture.model().isPublished)
    #expect(Fixture.model(manifestSHA256: String(repeating: "c", count: 64)).isPublished)
  }

  @Test func withoutTheManifestPinItIsNot() {
    #expect(!PublishedModel(repo: "owner/model", revision: Fixture.revisionA).isPublished)
    #expect(!Fixture.model(manifestSHA256: nil).isPublished)
    #expect(!Fixture.model(manifestSHA256: String(repeating: "C", count: 64)).isPublished)
  }

  @Test func branchesBadReposAndBadPinsAreNot() {
    #expect(!PublishedModel(repo: "owner/model", revision: "main").isPublished)
    #expect(!PublishedModel(repo: "model", revision: Fixture.revisionA).isPublished)
    #expect(!PublishedModel(repo: "owner/model", revision: Fixture.revisionA, manifestSHA256: "abc").isPublished)
  }

  @Test func filesResolveInTheBudgetFolderAtThePinnedCommit() {
    #expect(Fixture.model().url(for: "manifest.json").absoluteString
              == "https://huggingface.co/owner/model/resolve/\(Fixture.revisionA)/b70/manifest.json")
    let b280 = PublishedModel(repo: "owner/model", revision: Fixture.revisionA, budget: 280)
    #expect(b280.url(for: "EmbeddingGemma2.aar").absoluteString
              == "https://huggingface.co/owner/model/resolve/\(Fixture.revisionA)/b280/EmbeddingGemma2.aar")
  }
}

struct ChecksumTests {
  @Test func hashesKnownVectors() {
    #expect(Checksum.sha256(data: Data("abc".utf8))
              == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func streamsFilesLargerThanOneChunk() throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let data = Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let url = dir.url.appending(path: "big.bin")
    try data.write(to: url)
    #expect(try Checksum.sha256(file: url) == Checksum.sha256(data: data))
  }

  @Test func verifiesSizeAndHash() throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let url = dir.url.appending(path: "f")
    try Data("abc".utf8).write(to: url)
    let sha = Checksum.sha256(data: Data("abc".utf8))
    #expect(Checksum.verifies(url, size: 3, sha256: sha))
    #expect(!Checksum.verifies(url, size: 4, sha256: sha))
    #expect(!Checksum.verifies(url, size: 3, sha256: String(repeating: "0", count: 64)))
    #expect(!Checksum.verifies(dir.url.appending(path: "missing"), size: 3, sha256: sha))
  }
}

struct InstallSpaceTests {
  private let sha = String(repeating: "0", count: 64)

  @Test func needsTheArchiveItsExtractedFilesAndTheCompiledModel() {
    let m = ModelManifest(archive: "m.aar", size: 350, sha256: sha, unpackedSize: 450)
    #expect(InstallSpace.required(m, alreadyDownloaded: 0) == 350 + 2 * 450)
    #expect(InstallSpace.required(m, alreadyDownloaded: 350) == 2 * 450)
  }

  @Test func withoutAnUnpackedSizeItIsAboutTwoAndAHalfTimesTheArchive() {
    let m = ModelManifest(archive: "m.aar", size: 400, sha256: sha)
    #expect(InstallSpace.required(m, alreadyDownloaded: 0) == 1_000)
  }

  @Test func refusesWhenShortAndSkipsWhenUnknown() throws {
    let m = ModelManifest(archive: "m.aar", size: 400, sha256: sha)
    #expect(throws: ModelInstallError.insufficientSpace(required: 1_000, available: 999)) {
      try InstallSpace.check(m, alreadyDownloaded: 0, available: 999)
    }
    try InstallSpace.check(m, alreadyDownloaded: 0, available: 1_000)
    try InstallSpace.check(m, alreadyDownloaded: 0, available: nil)
  }
}

struct DownloadPolicyTests {
  private func path(wifi: Bool = true, expensive: Bool = false, constrained: Bool = false,
                    satisfied: Bool = true) -> NetworkPath {
    NetworkPath(isSatisfied: satisfied, isWiFi: wifi, isExpensive: expensive, isConstrained: constrained)
  }

  @Test func plainWiFiDownloads() {
    #expect(DownloadPolicy.wait(on: path(), allowCellular: false) == nil)
  }

  @Test func cellularHotspotsAndOfflineWaitForWiFi() {
    #expect(DownloadPolicy.wait(on: .cellular, allowCellular: false) == .wifi)
    #expect(DownloadPolicy.wait(on: path(expensive: true), allowCellular: false) == .wifi)  // personal hotspot
    #expect(DownloadPolicy.wait(on: .offline, allowCellular: false) == .wifi)
    #expect(DownloadPolicy.wait(on: path(wifi: false, expensive: true, constrained: true), allowCellular: false) == .wifi)
  }

  @Test func lowDataModeIsTreatedLikeCellular() {
    #expect(DownloadPolicy.wait(on: path(constrained: true), allowCellular: false) == .lowDataMode)
  }

  @Test func allowingMobileDataLiftsEveryRule() {
    for p in [NetworkPath.cellular, path(constrained: true), path(expensive: true), .wifi] {
      #expect(DownloadPolicy.wait(on: p, allowCellular: true) == nil)
    }
  }
}
