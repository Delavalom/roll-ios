import CoreGraphics
import Foundation
import Signals
import Store

// The text pass's inputs and outputs as protocols, so tests inject fakes. Production conformances: `TextRecognizer`
// (Signals), `Repositories` (Store) and, for images, the Indexer's `LibrarySource` (`PhotoLibrary`).

/// Reads the words in an image (`TextRecognizer`).
public protocol TextSource: Sendable {
  /// Names the reader's settings (stored with each text).
  var revision: String { get }
  /// "" for no text; nil if reading failed. Throws only on cancellation.
  func recognize(_ image: CGImage) async throws(CancellationError) -> String?
}

/// The Store calls the text pass makes. It writes the text tables only (`commitText`), never signals or vectors.
public protocol TextRepository: Sendable {
  func textCandidateIds(revision: String, retryUnread: Bool, limit: Int) async throws -> [String]
  func textCandidateCount(revision: String, retryUnread: Bool) async throws -> Int
  func commitText(_ items: [TextFields]) async throws
}

extension TextRecognizer: TextSource {}
extension Repositories: TextRepository {}

public struct TextPassConfig: Sendable {
  /// Long side of the image read, in pixels. The 300 px analysis thumbnail is too small: on the Mac, `.accurate` found
  /// 30% of the words at 300 px (4-16% on screenshots), 93% at 960 px and 93% at 1,600 px in about the same time
  /// (docs/investigations/evidence/2026-10-29-ocr/mac-ocr.json). Part of `TextIndexer.revision`.
  public var side = 960
  /// Images read between commits (the last ones are committed at the end, and on cancellation).
  public var commitEvery = 20

  public init() {}

  /// A local preview (an iCloud original's degraded image) is read only if it is about the requested size: a resize
  /// can come back a few pixels short, so 90% of `side`. Smaller previews are recorded unread.
  var minimumPreviewSide: Int { side * 9 / 10 }
}

/// What one `TextIndexer.run` did.
public struct TextReport: Sendable, Equatable {
  /// Images read (whether or not they had words).
  public var read = 0
  /// Read images with at least one search term.
  public var withWords = 0
  /// Images with no usable image (in iCloud, or only a small preview): recorded unread, retried with the network.
  public var unread = 0
  /// Failed loads and Vision errors: also recorded unread.
  public var failed = 0
  /// Thermal polls slept.
  public var thermalPolls = 0

  public init(read: Int = 0, withWords: Int = 0, unread: Int = 0, failed: Int = 0, thermalPolls: Int = 0) {
    self.read = read; self.withWords = withWords; self.unread = unread; self.failed = failed
    self.thermalPolls = thermalPolls
  }
}
