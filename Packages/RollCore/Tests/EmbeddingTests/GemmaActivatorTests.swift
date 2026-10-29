import EmbeddingGemma
import Foundation
import ModelInstall
import Testing
@testable import Embedding

struct GemmaActivatorTests {
  private let identity = ModelIdentity(repo: "owner/model", revision: String(repeating: "a", count: 40))

  /// A temporary folder holding a package store (`store/`), deleted by the caller.
  private func scratch() throws -> (dir: URL, activator: GemmaActivator) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "GemmaActivatorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, GemmaActivator(store: ModelStore(root: dir.appending(path: "store"))))
  }

  @Test func theManifestRequiresExactlyTheFunctionsThePackageLoads() {
    let package = Set(EmbeddingGemma.textFunctions + EmbeddingGemma.imageFunctions(budget: 70)
                        + EmbeddingGemma.imageFunctions(budget: 280))
    #expect(ModelManifest.requiredFunctions == package)
  }

  @Test func theArchiveMustHoldThePackageAndTokenizerNamesThePackageInstalls() {
    #expect(ModelManifest.requiredFiles.contains("\(ModelStore.packageName)/Manifest.json"))
    #expect(ModelManifest.requiredFiles.contains("\(ModelStore.tokenizerDir)/tokenizer.json"))
  }

  @Test func onlyMissingFilesMeanADownload() {
    let activator = GemmaActivator()
    #expect(activator.needsRedownload(EmbeddingGemmaError.downloadFailed(underlying: URLError(.fileDoesNotExist))))
    // Not thrown by `.installed` (nothing is checked against a list), so not a reason to download either.
    #expect(!activator.needsRedownload(EmbeddingGemmaError.checksumMismatch(file: "tokenizer/tokenizer.json")))
    #expect(!activator.needsRedownload(EmbeddingGemmaError.modelLoadFailed(underlying: URLError(.unknown))))
    #expect(!activator.needsRedownload(EmbeddingGemmaError.insufficientStorage(required: 2, available: 1)))
    #expect(!activator.needsRedownload(EmbeddingGemmaError.storageFailed(underlying: URLError(.unknown))))
    #expect(!activator.needsRedownload(CancellationError()))
    #expect(activator.keepAfterActivation.isEmpty)
  }

  /// Roll's folder already emptied by an earlier activation and the package's install deleted since: what the package
  /// really throws has to mean a download, or Roll would fail the same way on every launch.
  @Test func withNeitherTheFilesNorThePackagesInstallTheModelIsDownloadedAgain() async throws {
    let (dir, activator) = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let emptied = dir.appending(path: "model")
    try FileManager.default.createDirectory(at: emptied, withIntermediateDirectories: true)

    for folder in [emptied, dir.appending(path: "gone")] {
      let error = await #expect(throws: EmbeddingGemmaError.self) { try await activator.activate(folder, as: identity) }
      #expect(activator.needsRedownload(try #require(error)))
    }
  }

  /// A package that doesn't compile: the package gives the files back, and the folder is kept for a retry.
  @Test func aCompileFailureKeepsTheFolder() async throws {
    let (dir, activator) = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appending(path: "model")
    // A well-formed package manifest (Core ML aborts the process on a malformed one) naming a spec that isn't one.
    let manifest = """
      {"fileFormatVersion": "1.0.0", "rootModelIdentifier": "m", "itemInfoEntries": {"m": {"author": \
      "com.apple.CoreML", "description": "CoreML Model Specification", "name": "model.mlmodel", \
      "path": "com.apple.CoreML/model.mlmodel"}}}
      """
    let files = ["\(ModelStore.packageName)/Manifest.json": manifest,
                 "\(ModelStore.packageName)/Data/com.apple.CoreML/model.mlmodel": "not a model",
                 "tokenizer/tokenizer.json": "{}", "tokenizer/tokenizer_config.json": "{}"]
    for (file, text) in files {
      let url = folder.appending(path: file)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    let error = try #require(await #expect(throws: EmbeddingGemmaError.self) {
      try await activator.activate(folder, as: identity)
    })
    guard case .modelLoadFailed = error else { Issue.record("expected modelLoadFailed, got \(error)"); return }
    #expect(!activator.needsRedownload(error))
    for file in files.keys { #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path)) }
  }
}
