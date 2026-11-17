import Foundation
import os

/// Where Roll keeps the model: the App Group container when Roll has one, else Application Support.
///
/// Why the group: iOS's Neural Engine cache keys a compiled model by its path, and the app's data container moves on
/// every install and update, so each update compiled every function again (45–230 s each). An App Group container's
/// path doesn't move with updates, so after an update the functions should load from the cache (about 3.5 s each).
/// An experiment (docs/superpowers/specs/2026-11-16-durable-setup-design.md): kept only if a TestFlight update shows
/// it working.
///
/// Two folders move: Roll's install root (`ModelInstaller.defaultRoot`) and the package's store (`GemmaLoader.store`),
/// which holds the model and its compiled form once activated. Neither records absolute paths.
///
/// The first launch with the group moves the existing model there (a rename on the same volume, never a download; it
/// costs one cold compile, at the new path). If the move fails, the old folder stays in use.
public enum ModelLocation {
  public static let appGroup = "group.com.delavalom.roll"
  static let folderName = "RollModel"

  /// `local` (a folder in Application Support: Roll's `RollModel`, the package's `EmbeddingGemma`) or the folder of the
  /// same name under `sharedSupport` (the group container's Library/Application Support), moving `local` there first
  /// when only it exists. `sharedSupport` nil (no group): `local`.
  public static func resolve(local: URL, sharedSupport: URL?, fileManager: FileManager = .default) -> URL {
    guard let sharedSupport else { return local }
    let shared = sharedSupport.appending(path: local.lastPathComponent)
    let hasShared = fileManager.fileExists(atPath: shared.path)
    let hasLocal = fileManager.fileExists(atPath: local.path)
    if hasLocal, !hasShared {
      do {
        try fileManager.createDirectory(at: sharedSupport, withIntermediateDirectories: true)
        try fileManager.moveItem(at: local, to: shared)
      } catch {
        Logger(subsystem: "com.delavalom.roll", category: "model")
          .error("moving the model to the App Group failed: \(String(describing: error), privacy: .public)")
        return local
      }
    } else if hasLocal, hasShared {
      // A move that copied but didn't remove (or an older build reinstalled the model): the group's copy wins. Removed
      // off the launch path (hundreds of MB): set aside by a rename, deleted in the background.
      let trash = local.deletingLastPathComponent().appending(path: ".\(local.lastPathComponent)-removed-\(UUID().uuidString)")
      if (try? fileManager.moveItem(at: local, to: trash)) != nil {
        let path = trash.path
        DispatchQueue.global(qos: .utility).async { try? FileManager().removeItem(atPath: path) }
      }
    }
    return shared
  }

  /// The group container's Library/Application Support, when Roll has the App Group entitlement.
  public static func groupSupport(fileManager: FileManager = .default) -> URL? {
    fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appending(path: "Library/Application Support", directoryHint: .isDirectory)
  }
}
