import Foundation

/// One photo or video that may go into a memory reel. Built from what the app already knows about an asset: library
/// metadata, Vision aesthetics (`AssetRecord.aesthetic`) and the similar-shot groups from `DuplicateGrouper` with the
/// `KeeperPolicy` pick marked.
public struct ReelCandidate: Sendable, Equatable, Identifiable {
  public var id: String
  public var created: Date
  public var isVideo: Bool
  /// Seconds; zero for photos.
  public var duration: TimeInterval
  /// Vision overall aesthetic (about -1...1). Nil sorts below every real score.
  public var aesthetic: Double?
  /// Screenshots and documents (`AssetRecord.isUtility`, or the screenshot subtype) never go into a memory.
  public var isScreenshotOrDocument: Bool
  /// The `DuplicateGrouper` group this shot belongs to (any stable label), nil when it has no look-alikes.
  public var similarGroup: String?
  /// True for the group's `KeeperPolicy` pick. Ignored when `similarGroup` is nil.
  public var isKeeper: Bool

  public init(id: String, created: Date, isVideo: Bool = false, duration: TimeInterval = 0, aesthetic: Double? = nil,
              isScreenshotOrDocument: Bool = false, similarGroup: String? = nil, isKeeper: Bool = true) {
    self.id = id; self.created = created; self.isVideo = isVideo; self.duration = duration; self.aesthetic = aesthetic
    self.isScreenshotOrDocument = isScreenshotOrDocument; self.similarGroup = similarGroup; self.isKeeper = isKeeper
  }
}
