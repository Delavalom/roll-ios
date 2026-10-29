import Foundation
import Synchronization

/// Where getting the model ready stands, for the "On-device AI" row.
public enum InstallStep: Sendable, Equatable {
  /// The network doesn't allow the download (`DownloadPolicy`): it is queued and starts by itself once it does. The
  /// size once the manifest is known.
  case waiting(NetworkWait, totalBytes: Int64?)
  case downloading(completedBytes: Int64, totalBytes: Int64)
  case unpacking
  /// Loading the model; the first time, the activator installs and compiles it.
  case activating
}

/// The repo and revision a model folder holds (from its marker, so an older revision's folder is never labelled
/// with the current one): what the activator installs it as.
public struct ModelIdentity: Sendable, Equatable {
  public let repo: String
  public let revision: String

  public init(repo: String, revision: String) {
    self.repo = repo
    self.revision = revision
  }
}

/// Turns an extracted folder into a usable model. The app's activator goes through the EmbeddingGemma package
/// (`EmbeddingGemma.load(.installed(_:repo:revision:))`, which moves the files into its store, compiles once and
/// then reuses the compiled model); fakes in tests.
public protocol ModelActivator<Model>: Sendable {
  associatedtype Model: Sendable
  /// Loads `identity` from `folder`, the extracted archive (`<revision>/model/`). The activator may move `folder`
  /// away; once it has installed `identity`, later calls must load without it.
  func activate(_ folder: URL, as identity: ModelIdentity) async throws -> Model
  /// Entries of the revision folder to keep once activated besides the marker; everything else is deleted to free
  /// the space.
  var keepAfterActivation: Set<String> { get }
  /// True if `error` means the model's files are gone or damaged, so only a new download can help. Anything else
  /// (a compile or load failure) keeps the folder, so a retry doesn't download again.
  func needsRedownload(_ error: any Error) -> Bool
  /// After an activation of the current revision and Roll's cleanup: the activator drops its own older installs.
  func didActivate() async
}

/// Downloads, verifies, extracts and activates the published model, one revision at a time.
///
/// - `prepare` downloads `manifest.json` (checked against the pinned hash), then the archive into
///   `<revision>.partial/` (resumable). The finished download is renamed to the archive's own name, which the
///   transport never writes, before it is checked against the manifest's size and SHA-256, and extracted from that
///   same file, into `unpacked/model/`. The files the package needs are checked, the result is renamed to
///   `<revision>/` in one step, and only then is the archive deleted.
/// - Activating hands `<revision>/model/` and the marker's repo and revision to the activator. The package moves the
///   files into its store (no copy) and compiles there, so only the marker is left here; a later launch loads the
///   package's install without them.
/// - `load` uses `<revision>/` when it's there. While it isn't but an older revision is installed, it loads that one
///   and stages the new one on Wi-Fi in the background: the switch happens on a later launch, never mid-session, and
///   the old folders are deleted only after the new revision activated.
/// - One `prepare` runs at a time; a second caller joins it, unless it allows cellular and the running one doesn't,
///   in which case the running one is cancelled (its resume data kept) and restarted with cellular allowed.
public actor ModelInstaller {
  public nonisolated let model: PublishedModel
  public nonisolated let root: URL
  private let transport: any ModelTransport
  private let extractor: any ArchiveExtractor
  private let conditions: InstallConditions
  private nonisolated let folders: ModelFolders
  private nonisolated let reporters = Mutex<[UUID: @Sendable (InstallStep) -> Void]>([:])
  private var inFlight: (id: UUID, allowCellular: Bool, task: Task<URL, any Error>)?
  private var background: Task<Void, Never>?

  /// `Application Support/RollModel`.
  public static var defaultRoot: URL { URL.applicationSupportDirectory.appending(path: "RollModel") }

  public init(model: PublishedModel, root: URL = ModelInstaller.defaultRoot, transport: any ModelTransport,
              extractor: any ArchiveExtractor = AppleArchiveExtractor(), conditions: InstallConditions) {
    self.model = model
    self.root = root
    self.transport = transport
    self.extractor = extractor
    self.conditions = conditions
    folders = ModelFolders(root: root, model: model)
  }

  public func localState() -> LocalModelState { folders.state() }

  // MARK: - Load

  /// `model` (the app passes `PublishedModel.current(budget:)`), or, while that one downloads, the last installed
  /// one, downloading it first if needed. Throws `.notPublished` until the published values are set.
  public func load<A: ModelActivator>(allowCellular: Bool = false, activator: A,
                                      report: @escaping @Sendable (InstallStep) -> Void) async throws -> A.Model {
    guard model.isPublished else { throw ModelInstallError.notPublished }
    switch folders.state() {
    case .staged(let folder), .installed(let folder):
      report(.activating)
      do { return try await activate(folder, activator) } catch {
        guard !(error is CancellationError), activator.needsRedownload(error) else { throw error }
        await discard(folder)
      }
    case .absent, .partial:
      if let old = folders.fallback() {
        report(.activating)
        do {
          let loaded = try await Self.load(old, activator)
          stageInBackground()
          return loaded
        } catch {
          if error is CancellationError { throw error }
          if activator.needsRedownload(error) { await discard(old) }
        }
      }
    }
    let folder = try await prepare(allowCellular: allowCellular, report: report)
    report(.activating)
    do { return try await activate(folder, activator) } catch {
      if !(error is CancellationError), activator.needsRedownload(error) { await discard(folder) }
      throw error
    }
  }

  private func activate<A: ModelActivator>(_ folder: URL, _ activator: A) async throws -> A.Model {
    let loaded = try await Self.load(folder, activator)
    // The model is loaded from the activator's own install, so freeing what is left of ours can't break it; a
    // failure here only costs disk space until the next launch tries again.
    let folders = folders, keep = activator.keepAfterActivation
    try? await Self.offActor {
      try? folders.markInstalled(keeping: keep)
      folders.removeOthers()
    }
    await activator.didActivate()
    return loaded
  }

  /// `folder`'s extracted model, as the repo and revision its marker names.
  private nonisolated static func load<A: ModelActivator>(_ folder: URL, _ activator: A) async throws -> A.Model {
    guard let marker = ModelFolders.Marker.read(folder) else {
      throw ModelInstallError.storageFailed("\(folder.lastPathComponent) has no \(ModelFolders.markerName)")
    }
    return try await activator.activate(ModelFolders.model(in: folder), as: marker.identity)
  }

  private func discard(_ folder: URL) async { await Self.remove(folder) }

  /// File work that takes seconds on a phone (hashing hundreds of MB, deleting a model folder), off the actor so
  /// `localState()` and joining callers aren't held up. Detached: it finishes even if the caller is cancelled.
  private nonisolated static func offActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility) { try work() }.value
  }

  private nonisolated static func remove(_ url: URL) async {
    try? await offActor { try? FileManager.default.removeItem(at: url) }
  }

  private nonisolated static func verifies(_ file: URL, _ manifest: ModelManifest) async -> Bool {
    (try? await offActor { Checksum.verifies(file, size: manifest.size, sha256: manifest.sha256) }) ?? false
  }

  /// Stages the current revision on Wi-Fi while an older one is in use. Errors are dropped: the next launch retries.
  private func stageInBackground() {
    guard background == nil else { return }
    background = Task { _ = try? await self.prepare(allowCellular: false) { _ in } }
  }

  // MARK: - Prepare

  /// Downloads, verifies and extracts the current revision; returns `<revision>/`.
  public func prepare(allowCellular: Bool, report: @escaping @Sendable (InstallStep) -> Void) async throws -> URL {
    guard model.isPublished else { throw ModelInstallError.notPublished }
    let reporter = UUID()
    reporters.withLock { $0[reporter] = report }
    defer { _ = reporters.withLock { $0.removeValue(forKey: reporter) } }

    if let running = inFlight {
      if running.allowCellular || !allowCellular { return try await running.task.value }
      running.task.cancel()
      _ = try? await running.task.value
      if inFlight?.id == running.id { inFlight = nil }
    }
    if let running = inFlight { return try await running.task.value }  // another caller restarted it meanwhile
    let id = UUID()
    let task = Task { try await self.run(allowCellular: allowCellular) }
    inFlight = (id, allowCellular, task)
    defer { if inFlight?.id == id { inFlight = nil } }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  private nonisolated func emit(_ step: InstallStep) {
    for report in reporters.withLock({ Array($0.values) }) { report(step) }
  }

  private func run(allowCellular: Bool) async throws -> URL {
    if case .staged(let folder) = folders.state() { return folder }
    if case .installed(let folder) = folders.state() { return folder }
    let fm = FileManager.default
    do {
      try folders.prepareRoot()
      try fm.createDirectory(at: folders.partial, withIntermediateDirectories: true)
    } catch { throw ModelInstallError.storageFailed(error.localizedDescription) }

    let manifest = try await fetchManifest(allowCellular: allowCellular)
    let archive = folders.partial.appending(path: manifest.archive)
    try await fetchArchive(manifest, to: archive, allowCellular: allowCellular)
    try Task.checkCancellation()

    emit(.unpacking)
    let unpacked = folders.unpacked, extracted = ModelFolders.model(in: unpacked)
    await Self.remove(unpacked)
    do { try fm.createDirectory(at: extracted, withIntermediateDirectories: true) } catch {
      throw ModelInstallError.storageFailed(error.localizedDescription)
    }
    let extractor = extractor
    do {
      try await Self.offActor { try extractor.extract(archive, into: extracted) }
    } catch ModelInstallError.insufficientSpace {
      // The extractor knows only that the volume filled up; say how much the whole install needs.
      await Self.remove(unpacked)
      throw ModelInstallError.insufficientSpace(
        required: InstallSpace.required(manifest, alreadyDownloaded: manifest.size),
        available: conditions.availableCapacity(root) ?? 0)
    }
    for required in ModelManifest.requiredFiles where !fm.fileExists(atPath: extracted.appending(path: required).path) {
      await Self.remove(unpacked)
      throw ModelInstallError.badArchive("\(required) is missing")
    }
    do {
      try ModelFolders.Marker(repo: model.repo, revision: model.revision, archiveSHA256: manifest.sha256,
                              installedAt: nil).write(unpacked)
      await Self.remove(folders.final)
      try fm.moveItem(at: unpacked, to: folders.final)
    } catch { throw ModelInstallError.storageFailed(error.localizedDescription) }
    // Installed: only now is the archive (inside the partial folder) deleted, before the activator compiles.
    await Self.remove(folders.partial)
    return folders.final
  }

  /// `manifest.json`: reused from an earlier attempt if it still matches the pin, else downloaded and checked.
  private func fetchManifest(allowCellular: Bool) async throws -> ModelManifest {
    let url = folders.manifest
    if let data = try? Data(contentsOf: url), pinned(data), let manifest = try? ModelManifest.decode(data) {
      return manifest
    }
    await gateNetwork(allowCellular: allowCellular, totalBytes: nil)
    let part = url.appendingPathExtension("download")
    try await download(model.url(for: ModelManifest.fileName), to: part, allowCellular: allowCellular) { _ in }
    let data: Data
    do { data = try Data(contentsOf: part) } catch { throw ModelInstallError.storageFailed(error.localizedDescription) }
    guard pinned(data) else {
      try? FileManager.default.removeItem(at: part)
      throw ModelInstallError.manifestMismatch
    }
    let manifest = try ModelManifest.decode(data)
    do {
      try? FileManager.default.removeItem(at: url)
      try FileManager.default.moveItem(at: part, to: url)
    } catch { throw ModelInstallError.storageFailed(error.localizedDescription) }
    return manifest
  }

  /// Always true for a published model (`isPublished` requires the pin); false if the pin is somehow missing.
  private func pinned(_ data: Data) -> Bool {
    model.manifestSHA256.map { Checksum.sha256(data: data) == $0 } ?? false
  }

  /// The archive at `destination`, verified. The transport only ever writes `<archive>.download`; the file is renamed
  /// to `destination` before it is hashed, so what was verified is what gets extracted. A complete `.download`
  /// (finished while Roll wasn't running) is used as is.
  private func fetchArchive(_ manifest: ModelManifest, to destination: URL, allowCellular: Bool) async throws {
    let available = { [conditions, root] in conditions.availableCapacity(root) }
    if await Self.verifies(destination, manifest) {
      try InstallSpace.check(manifest, alreadyDownloaded: manifest.size, available: available())
      return
    }
    let part = destination.appendingPathExtension("download")
    if Checksum.fileSize(part) == manifest.size {
      try claim(part, as: destination)
      if await Self.verifies(destination, manifest) {
        try InstallSpace.check(manifest, alreadyDownloaded: manifest.size, available: available())
        emit(.downloading(completedBytes: manifest.size, totalBytes: manifest.size))
        return
      }
    }
    await Self.remove(destination)
    try InstallSpace.check(manifest, alreadyDownloaded: 0, available: available())
    let total = manifest.size
    // `.downloading` only once the network allows it: while waiting, the transport reports no bytes, and a
    // "0 of 359 MB" would hide the waiting row and its mobile-data choice. The first progress callback says it began.
    if await gateNetwork(allowCellular: allowCellular, totalBytes: total) {
      emit(.downloading(completedBytes: 0, totalBytes: total))
    }
    try await download(model.url(for: manifest.archive), to: part, allowCellular: allowCellular) { bytes in
      self.emit(.downloading(completedBytes: min(bytes, total), totalBytes: total))
    }
    try claim(part, as: destination)
    guard await Self.verifies(destination, manifest) else {
      await Self.remove(destination)
      throw ModelInstallError.checksumMismatch(file: manifest.archive)
    }
    emit(.downloading(completedBytes: total, totalBytes: total))
  }

  /// Renames the transport's finished file to a name it never writes.
  private func claim(_ part: URL, as destination: URL) throws {
    let fm = FileManager.default
    do {
      try? fm.removeItem(at: destination)
      try fm.moveItem(at: part, to: destination)
    } catch { throw ModelInstallError.storageFailed(error.localizedDescription) }
  }

  private func download(_ url: URL, to destination: URL, allowCellular: Bool,
                        progress: @escaping @Sendable (Int64) -> Void) async throws {
    do { try await transport.download(url, to: destination, allowCellular: allowCellular, progress: progress) } catch {
      if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
      if let own = error as? ModelInstallError { throw own }
      throw ModelInstallError.downloadFailed(error.localizedDescription)
    }
  }

  /// The network doesn't allow the download yet: say why and return false. It is still started; the transport holds
  /// it until it may run.
  @discardableResult
  private func gateNetwork(allowCellular: Bool, totalBytes: Int64?) async -> Bool {
    let path = await conditions.network()
    guard let wait = DownloadPolicy.wait(on: path, allowCellular: allowCellular) else { return true }
    emit(.waiting(wait, totalBytes: totalBytes))
    return false
  }
}
