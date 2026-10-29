import AppleArchive
import Foundation
import Synchronization
import System
@testable import ModelInstall

/// A temporary folder, deleted by `cleanUp()`.
struct TempDir {
  let url = FileManager.default.temporaryDirectory.appending(path: "ModelInstallTests-\(UUID().uuidString)")
  init() { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

enum Fixture {
  static let revisionA = String(repeating: "a", count: 40)
  static let revisionB = String(repeating: "b", count: 40)
  /// A well-formed pin that matches no manifest: enough for a model that is already installed.
  static let anyPin = String(repeating: "d", count: 64)

  static func model(_ revision: String = revisionA, manifestSHA256: String? = anyPin) -> PublishedModel {
    PublishedModel(repo: "owner/model", revision: revision, manifestSHA256: manifestSHA256)
  }

  /// A small folder in the published archive layout (`required` false leaves the tokenizer out).
  static func modelFolder(in dir: URL, required: Bool = true, payload: String = "weights") throws -> URL {
    let src = dir.appending(path: "src-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: src.appending(path: "EmbeddingGemma2.mlpackage/Data/weights"),
                           withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: src.appending(path: "EmbeddingGemma2.mlpackage/Manifest.json"))
    try Data(payload.utf8).write(to: src.appending(path: "EmbeddingGemma2.mlpackage/Data/weights/weight.bin"))
    if required {
      try fm.createDirectory(at: src.appending(path: "tokenizer"), withIntermediateDirectories: true)
      try Data("{\"t\":1}".utf8).write(to: src.appending(path: "tokenizer/tokenizer.json"))
      try Data("{\"c\":1}".utf8).write(to: src.appending(path: "tokenizer/tokenizer_config.json"))
    }
    return src
  }

  /// `folder` as an LZFSE Apple Archive at `out`.
  static func archive(_ folder: URL, to out: URL) throws {
    let file = ArchiveByteStream.fileStream(path: FilePath(out.path), mode: .writeOnly, options: [.create, .truncate],
                                            permissions: FilePermissions(rawValue: 0o644))!
    let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file)!
    let encoder = ArchiveStream.encodeStream(writingTo: compressed)!
    try encoder.writeDirectoryContents(archiveFrom: FilePath(folder.path),
                                       keySet: ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DAT,MOD")!)
    try encoder.close()
    try compressed.close()
    try file.close()
  }

  /// The archive bytes and a matching manifest for a fresh model folder.
  static func published(in dir: URL, required: Bool = true, payload: String = "weights",
                        unpackedSize: Int64? = nil) throws -> (archive: Data, manifest: Data) {
    let src = try modelFolder(in: dir, required: required, payload: payload)
    let out = dir.appending(path: "\(UUID().uuidString).aar")
    try archive(src, to: out)
    let data = try Data(contentsOf: out)
    return (data, manifestJSON(size: Int64(data.count), sha256: Checksum.sha256(data: data), unpackedSize: unpackedSize))
  }

  static func manifestJSON(archive: String = "EmbeddingGemma2.aar", size: Int64, sha256: String,
                           unpackedSize: Int64? = nil) -> Data {
    var object: [String: Any] = ["format": 1, "archive": archive, "size": size, "sha256": sha256]
    if let unpackedSize { object["unpacked_size"] = unpackedSize }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

/// Serves files by URL (last path component), with switches for the cases under test. No network.
final class FakeTransport: ModelTransport {
  struct Call: Equatable {
    let file: String
    let allowCellular: Bool
  }

  private struct State {
    var files: [String: Data] = [:]
    var calls: [Call] = []
    /// Files whose download waits until the calling task is cancelled.
    var hanging: Set<String> = []
    var delay: Duration = .zero
  }

  private let state = Mutex(State())

  init(_ files: [String: Data] = [:]) { state.withLock { $0.files = files } }

  var calls: [Call] { state.withLock { $0.calls } }
  /// The SHA-256 of the `manifest.json` it serves: what a build would pin.
  var pin: String? { state.withLock { $0.files[ModelManifest.fileName] }.map { Checksum.sha256(data: $0) } }
  func calls(for file: String) -> [Call] { calls.filter { $0.file == file } }
  func file(_ name: String) -> Data? { state.withLock { $0.files[name] } }
  func serve(_ file: String, _ data: Data) { state.withLock { $0.files[file] = data } }
  func remove(_ file: String) { state.withLock { _ = $0.files.removeValue(forKey: file) } }
  func hang(_ file: String, _ on: Bool = true) { state.withLock { if on { $0.hanging.insert(file) } else { $0.hanging.remove(file) } } }
  func setDelay(_ delay: Duration) { state.withLock { $0.delay = delay } }

  func download(_ url: URL, to destination: URL, allowCellular: Bool,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
    let file = url.lastPathComponent
    let (data, hangs, delay) = state.withLock { s in
      s.calls.append(Call(file: file, allowCellular: allowCellular))
      return (s.files[file], s.hanging.contains(file), s.delay)
    }
    if hangs { try await Task.sleep(for: .seconds(3600)) }
    if delay > .zero { try await Task.sleep(for: delay) }
    guard let data else { throw URLError(.fileDoesNotExist) }
    progress(Int64(data.count / 2))
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination)
    progress(Int64(data.count))
  }
}

struct ActivationError: Error, Equatable {
  let redownload: Bool
}

/// What `FakeActivator` loaded: the folder it was handed and the identity it installed it as.
struct Activation: Equatable, Sendable {
  let folder: URL
  let identity: ModelIdentity
}

/// Records what it activates; can fail on demand. With a `store` it behaves like the package's `.installed`: an
/// install of that repo and revision already in the store is returned without touching the folder, else the folder
/// is moved there, and with neither it fails as needing a download.
final class FakeActivator: ModelActivator {
  private let state = Mutex<(activated: [Activation], failures: [ActivationError], didActivate: Int)>(([], [], 0))
  private let store: URL?

  init(store: URL? = nil) { self.store = store }

  var activated: [Activation] { state.withLock { $0.activated } }
  var didActivateCount: Int { state.withLock { $0.didActivate } }
  /// The next activations throw these, in order.
  func fail(with errors: ActivationError...) { state.withLock { $0.failures = errors } }

  func activate(_ folder: URL, as identity: ModelIdentity) async throws -> Activation {
    let activation = Activation(folder: folder, identity: identity)
    let failure = state.withLock { s -> ActivationError? in
      s.activated.append(activation)
      return s.failures.isEmpty ? nil : s.failures.removeFirst()
    }
    if let failure { throw failure }
    if let store {
      let fm = FileManager.default
      let installed = store.appending(path: identity.repo.replacingOccurrences(of: "/", with: "--"))
        .appending(path: identity.revision)
      if fm.fileExists(atPath: installed.path) { return activation }
      guard fm.fileExists(atPath: folder.path) else { throw ActivationError(redownload: true) }
      try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.moveItem(at: folder, to: installed)
    }
    return activation
  }

  var keepAfterActivation: Set<String> { [] }
  func needsRedownload(_ error: any Error) -> Bool { (error as? ActivationError)?.redownload ?? false }
  func didActivate() async { state.withLock { $0.didActivate += 1 } }
}

/// Collects the reported steps.
final class Steps: Sendable {
  private let steps = Mutex<[InstallStep]>([])
  var all: [InstallStep] { steps.withLock { $0 } }
  var report: @Sendable (InstallStep) -> Void { { [self] step in steps.withLock { $0.append(step) } } }
}

/// Runs a closure before extracting with the real extractor, or throws instead.
struct HookedExtractor: ArchiveExtractor {
  var before: @Sendable (URL) throws -> Void = { _ in }

  func extract(_ archive: URL, into directory: URL) throws {
    try before(archive)
    try AppleArchiveExtractor().extract(archive, into: directory)
  }
}

extension InstallConditions {
  static func fixed(_ path: NetworkPath = .wifi, available: Int64? = 1 << 40) -> InstallConditions {
    InstallConditions(network: { path }, availableCapacity: { _ in available })
  }
}
