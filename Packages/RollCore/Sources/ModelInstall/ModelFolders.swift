import Foundation

/// Where a published revision stands on disk, without network.
public enum LocalModelState: Sendable, Equatable {
  /// Nothing of this revision yet.
  case absent
  /// A download or extraction started and didn't finish (kept: the next attempt resumes it).
  case partial
  /// Downloaded, verified and extracted, not activated yet.
  case staged(URL)
  /// Activated once: the activator took the extracted model (the package moves it into its store), so only the
  /// marker is left in the folder.
  case installed(URL)
}

/// Roll's model folders under one root (`Application Support/RollModel`, excluded from backups):
///
/// ```
/// <owner--name>/<revision>.partial/   manifest.json, the archive (+ .download, .resume while it downloads), unpacked/
/// <owner--name>/<revision>/           .roll-model.json and model/ (the extracted archive), renamed from unpacked/
///                                     in one step
/// ```
/// A `<revision>/` folder exists only once everything in it is verified and extracted; its marker says whether the
/// activator has installed it. The activator gets `model/` and may move it away (the package does), so the marker,
/// next to it, stays.
struct ModelFolders: Sendable {
  static let markerName = ".roll-model.json"
  static let unpackedName = "unpacked"
  static let modelName = "model"

  let root: URL
  let model: PublishedModel

  var repoFolder: URL { root.appending(path: model.repoFolderName) }
  var final: URL { repoFolder.appending(path: model.revision) }
  var partial: URL { repoFolder.appending(path: "\(model.revision).partial") }
  var manifest: URL { partial.appending(path: ModelManifest.fileName) }
  var unpacked: URL { partial.appending(path: Self.unpackedName) }

  /// The extracted archive inside a `<revision>/` (or `unpacked/`) folder.
  static func model(in folder: URL) -> URL { folder.appending(path: modelName) }

  struct Marker: Codable, Equatable {
    var repo: String
    var revision: String
    var archiveSHA256: String
    var installedAt: Date?

    var identity: ModelIdentity { ModelIdentity(repo: repo, revision: revision) }

    static func read(_ folder: URL) -> Marker? {
      guard let data = try? Data(contentsOf: folder.appending(path: ModelFolders.markerName)) else { return nil }
      return try? JSONDecoder().decode(Marker.self, from: data)
    }

    func write(_ folder: URL) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(self).write(to: folder.appending(path: ModelFolders.markerName), options: .atomic)
    }
  }

  func state() -> LocalModelState {
    let fm = FileManager.default
    if let marker = Marker.read(final), marker.repo == model.repo, marker.revision == model.revision {
      return marker.installedAt == nil ? .staged(final) : .installed(final)
    }
    return fm.fileExists(atPath: partial.path) ? .partial : .absent
  }

  /// The newest installed folder of any other revision or repo: what to use while the current one downloads.
  func fallback() -> URL? {
    var best: (URL, Date)?
    for folder in revisionFolders() where folder.standardizedFileURL != final.standardizedFileURL {
      guard let marker = Marker.read(folder), let at = marker.installedAt else { continue }
      if best.map({ at > $0.1 }) ?? true { best = (folder, at) }
    }
    return best?.0
  }

  /// Creates the root (excluded from backups: the model can always be downloaded again).
  func prepareRoot() throws {
    var url = root
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  /// Marks `final` installed and frees what the activator doesn't need: every entry except the marker and `keep`.
  func markInstalled(keeping keep: Set<String>) throws {
    let fm = FileManager.default
    guard var marker = Marker.read(final) else { return }
    if marker.installedAt == nil {
      marker.installedAt = Date()
      try marker.write(final)
    }
    for child in try fm.contentsOfDirectory(atPath: final.path)
    where child != Self.markerName && !keep.contains(child) {
      try fm.removeItem(at: final.appending(path: child))
    }
  }

  /// Deletes every folder of other revisions and repos (and a leftover partial of this one).
  func removeOthers() {
    let fm = FileManager.default
    for repo in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
      guard repo.standardizedFileURL == repoFolder.standardizedFileURL else {
        try? fm.removeItem(at: repo)
        continue
      }
      for folder in (try? fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil)) ?? []
      where folder.standardizedFileURL != final.standardizedFileURL {
        try? fm.removeItem(at: folder)
      }
    }
  }

  private func revisionFolders() -> [URL] {
    let fm = FileManager.default
    return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).flatMap { repo in
      ((try? fm.contentsOfDirectory(atPath: root.appending(path: repo).path)) ?? [])
        .filter { !$0.hasSuffix(".partial") && !$0.hasPrefix(".") }
        .map { root.appending(path: repo).appending(path: $0) }
    }
  }
}
