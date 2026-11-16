import CoreGraphics
import Foundation
import Signals
import Store

// The tag pass's inputs and outputs as protocols, so tests inject fakes. Production conformances: `SceneClassifier`
// (Signals), `Repositories` (Store) and, for images, the Indexer's `LibrarySource` (`PhotoLibrary`).

/// Labels what an image shows (`SceneClassifier`).
public protocol TagSource: Sendable {
  /// Names the classifier's settings (stored with each photo's tags).
  var revision: String { get }
  /// The labels kept; [] for none; nil if classifying failed. Throws only on cancellation.
  func classify(_ image: CGImage) async throws(CancellationError) -> [SceneLabel]?
}

/// The Store calls the tag pass makes. It writes the tag tables only (`commitTags`), never signals or vectors.
public protocol TagRepository: Sendable {
  func tagCandidateIds(revision: String, retryUnread: Bool, limit: Int) async throws -> [String]
  func tagCandidateCount(revision: String, retryUnread: Bool) async throws -> Int
  func commitTags(_ items: [TagFields]) async throws
}

extension SceneClassifier: TagSource {}
extension Repositories: TagRepository {}

public struct TagPassConfig: Sendable {
  /// Long side of the image classified, in pixels: what the find eval's labels were computed on (360 px,
  /// `App/QA/QAFindExporter`). Part of `TagIndexer.revision`.
  public var side = 360
  /// A local preview (an iCloud original's degraded image) is classified from this long side; smaller ones are
  /// recorded unread. Scene labels need far fewer pixels than words.
  public var minimumPreviewSide = 120
  /// Photos classified between commits (the last ones are committed at the end, and on cancellation).
  public var commitEvery = 50

  public init() {}
}

/// What one `TagIndexer.run` did.
public struct TagReport: Sendable, Equatable {
  /// Photos classified (whether or not any label cleared the threshold).
  public var read = 0
  /// Classified photos with at least one label.
  public var tagged = 0
  /// Photos with no usable local image: recorded unread, retried with the network.
  public var unread = 0
  /// Failed loads and Vision errors: also recorded unread.
  public var failed = 0
  /// Thermal polls slept.
  public var thermalPolls = 0

  public init(read: Int = 0, tagged: Int = 0, unread: Int = 0, failed: Int = 0, thermalPolls: Int = 0) {
    self.read = read; self.tagged = tagged; self.unread = unread; self.failed = failed
    self.thermalPolls = thermalPolls
  }
}
