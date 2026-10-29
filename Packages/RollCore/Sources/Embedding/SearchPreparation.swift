/// What "Preparing search" remembers (`AppModel.prepareIfNeeded`): once the model's functions are compiled for this
/// marker, later launches skip preparing and load them from iOS's Neural Engine cache.
///
/// That cache's key includes the compiled model's path (embeddinggemma-coreml `2026-10-27-ane-cache.md`, finding 3),
/// and the path is inside the app's data container, which every install and update moves. The build number alone
/// missed an install over the app with the same build (the 30k proof, 2026-10-29: the first search compiled inline,
/// 52.5 s), so the marker also holds the container path.
public enum SearchPreparation {
  /// `revision`: the embedder's (model and image budget). `version` / `build`: `CFBundleShortVersionString` /
  /// `CFBundleVersion`. `container`: the data container's path (`NSHomeDirectory()` on iOS).
  public static func marker(revision: String, version: String?, build: String?, container: String) -> String {
    "\(revision) \(version ?? "?") (\(build ?? "?")) \(container)"
  }
}
