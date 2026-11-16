import Foundation

/// Features that ship dark until they're measured on a phone. One switch each.
enum Features {
  /// "Make a video" on the album-created screen and on event sections (`MemoryReelPlanner` + `MemoryVideoExporter`).
  /// On in DEBUG; off in Release until the render time is measured on an iPhone and the orchestrator flips it.
  /// `-UITestReleaseFeatures` turns it off in DEBUG too, so demo recordings show what Release ships.
  static let memoryVideos: Bool = {
    #if DEBUG
    !ProcessInfo.processInfo.arguments.contains("-UITestReleaseFeatures")
    #else
    false
    #endif
  }()
}
