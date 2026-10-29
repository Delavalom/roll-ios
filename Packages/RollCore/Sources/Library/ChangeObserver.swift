import Foundation

/// What one Photos change notification did to the image/video set.
public struct LibraryChange: Sendable, Equatable {
  public var inserted: [String]
  public var removed: [String]
  /// Assets whose metadata changed in place (favorite toggled, ...). Favorites feed the keeper policy, so
  /// the Indexer refreshes these rows. Content changes are listed in `contentChanged` instead.
  public var changed: [String]
  /// Assets whose pixels changed (edited, edit reverted: `assetContentChanged` or a `hasAdjustments`
  /// flip). Their signals and vectors are stale: the Indexer re-indexes them.
  public var contentChanged: [String]
  /// PhotoKit could not describe the change incrementally (`hasIncrementalChanges == false`); the lists
  /// above are empty and the consumer must run a full `sync()`.
  public var requiresResync: Bool

  public init(inserted: [String] = [], removed: [String] = [], changed: [String] = [], contentChanged: [String] = [],
              requiresResync: Bool = false) {
    self.inserted = inserted; self.removed = removed; self.changed = changed; self.contentChanged = contentChanged
    self.requiresResync = requiresResync
  }

  public var isEmpty: Bool {
    inserted.isEmpty && removed.isEmpty && changed.isEmpty && contentChanged.isEmpty && !requiresResync
  }
}

#if canImport(Photos) && os(iOS)
import Photos

/// Wraps `PHPhotoLibraryChangeObserver`.
///
/// Single use: call `start()` once, iterate `changes`, then `stop()` (or just stop iterating; the stream's
/// termination unregisters the observer). A stopped observer cannot be restarted; make a new one.
/// Not unit-tested: it needs a live photo library.
public final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
  public let changes: AsyncStream<LibraryChange>
  private let continuation: AsyncStream<LibraryChange>.Continuation
  private let lock = NSLock()
  private var tracked: PHFetchResult<PHAsset>?
  private var started = false
  private var finished = false

  public override init() {
    (changes, continuation) = AsyncStream.makeStream(of: LibraryChange.self, bufferingPolicy: .unbounded)
    super.init()
    continuation.onTermination = { [weak self] _ in self?.terminated() }
  }

  /// Registers with the photo library. A second call is ignored (the observer is single-use), and so is a
  /// call after the stream ended (`stop()`, or the consumer stopped iterating).
  public func start() {
    // Registering inside the lock orders it against `terminated()`: either this runs first and the
    // termination unregisters afterwards, or the stream has already ended and nothing registers.
    lock.withLock {
      guard !started, !finished else { return }
      started = true
      tracked = PHAsset.fetchAssets(with: LibraryFetch.options(sorted: false))
      PHPhotoLibrary.shared().register(self)
    }
  }

  public func stop() {
    continuation.finish()  // onTermination unregisters
  }

  public func photoLibraryDidChange(_ changeInstance: PHChange) {
    let change: LibraryChange? = lock.withLock {
      guard let current = tracked, let details = changeInstance.changeDetails(for: current) else { return nil }
      tracked = details.fetchResultAfterChanges
      guard details.hasIncrementalChanges else { return LibraryChange(requiresResync: true) }
      var metadata: [String] = []
      var content: [String] = []
      for asset in details.changedObjects {
        if let objectDetails = changeInstance.changeDetails(for: asset), Self.contentChanged(objectDetails) {
          content.append(asset.localIdentifier)
        } else {
          metadata.append(asset.localIdentifier)
        }
      }
      return LibraryChange(
        inserted: details.insertedObjects.map(\.localIdentifier),
        removed: details.removedObjects.map(\.localIdentifier),
        changed: metadata, contentChanged: content)
    }
    if let change, !change.isEmpty { continuation.yield(change) }
  }

  private static func contentChanged(_ details: PHObjectChangeDetails<PHAsset>) -> Bool {
    if details.assetContentChanged { return true }
    guard let before = details.objectBeforeChanges as PHAsset?, let after = details.objectAfterChanges else { return false }
    return before.hasAdjustments != after.hasAdjustments
  }

  private func terminated() {
    lock.withLock { finished = true }
    PHPhotoLibrary.shared().unregisterChangeObserver(self)
  }

  deinit {
    continuation.finish()
    PHPhotoLibrary.shared().unregisterChangeObserver(self)
  }
}
#endif
