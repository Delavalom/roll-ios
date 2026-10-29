import Foundation

/// One asset to squish, as the commit planner hands it to a `SquishRunner`.
public struct SquishRequest: Sendable, Equatable {
  public let assetID: String
  /// The library's size estimate (the runner's free-space check uses it).
  public let estimatedBytes: Int64

  public init(assetID: String, estimatedBytes: Int64) {
    self.assetID = assetID; self.estimatedBytes = estimatedBytes
  }
}

// MARK: - The squish seam
//
// Mirrors the batch API of Squish's `ReplaceFlow` (`prepare(items, progress:) -> PrepareReport`, then
// `commitDeletes([Prepared]) -> CommitResult`) without depending on the Squish target. Once Squish merges, a small
// adapter conforms `ReplaceFlow` to `SquishRunner`: `SquishRequest` → `SquishItem` (adding the "Keep 4K" choice),
// `Prepared` ↔ `SquishedCopy`, `PrepareReport` → `SquishBatch`, `CommitResult` → `SquishDeletion`, and
// `ReplaceError.userDeclinedDelete` → `SquishRunnerError.userDeclinedDelete`.

public enum SquishStage: Sendable, Equatable {
  case downloading, encoding, verifying, saving
}

public struct SquishRunProgress: Sendable, Equatable {
  public let assetID: String
  public let stage: SquishStage
  /// 0...1 when the stage can tell (downloads), otherwise `nil`.
  public let fraction: Double?

  public init(assetID: String, stage: SquishStage, fraction: Double?) {
    self.assetID = assetID; self.stage = stage; self.fraction = fraction
  }
}

/// A verified smaller copy that sits in the library next to its still-present original.
public struct SquishedCopy: Sendable, Equatable {
  public let assetID: String
  public let newAssetID: String
  /// Measured sizes of the exported original and of the squished file.
  public let originalBytes: Int64
  public let newBytes: Int64

  public init(assetID: String, newAssetID: String, originalBytes: Int64, newBytes: Int64) {
    self.assetID = assetID; self.newAssetID = newAssetID; self.originalBytes = originalBytes; self.newBytes = newBytes
  }

  /// What deleting the original is expected to free (once Recently Deleted is emptied).
  public var estimatedSavings: Int64 { max(0, originalBytes - newBytes) }
}

public struct SquishFailure: Sendable, Equatable {
  public let assetID: String
  public let error: any Error
  /// A copy left behind by failed verification; remove it with the runner's discard call.
  public let leftoverCopyID: String?

  public init(assetID: String, error: any Error, leftoverCopyID: String? = nil) {
    self.assetID = assetID; self.error = error; self.leftoverCopyID = leftoverCopyID
  }

  public static func == (lhs: SquishFailure, rhs: SquishFailure) -> Bool {
    lhs.assetID == rhs.assetID && lhs.leftoverCopyID == rhs.leftoverCopyID && (lhs.error as NSError) == (rhs.error as NSError)
  }
}

/// The result of preparing a batch. Originals are never touched by `prepare`.
public struct SquishBatch: Sendable, Equatable {
  public var prepared: [SquishedCopy] = []
  public var failures: [SquishFailure] = []
  /// The run was cancelled; items after the cancel weren't attempted.
  public var cancelled = false

  public init(prepared: [SquishedCopy] = [], failures: [SquishFailure] = [], cancelled: Bool = false) {
    self.prepared = prepared; self.failures = failures; self.cancelled = cancelled
  }

  public var leftoverCopyIDs: [String] { failures.compactMap(\.leftoverCopyID) }
}

public struct SquishDeletion: Sendable, Equatable {
  /// Originals deleted (their copies replace them).
  public let deleted: [SquishedCopy]
  /// Skipped because the original changed (edited, favorited, re-albumed) or the copy vanished since `prepare`;
  /// their originals were not touched.
  public let skipped: [SquishedCopy]
  /// Skipped because the runner has no verified record of the copy (prepared before a relaunch, say): it can't check
  /// the pair, so the original was not touched. `reconcile()` on the next launch picks them up again.
  public let unregistered: [SquishedCopy]

  public init(deleted: [SquishedCopy], skipped: [SquishedCopy], unregistered: [SquishedCopy] = []) {
    self.deleted = deleted; self.skipped = skipped; self.unregistered = unregistered
  }
}

public enum SquishRunnerError: Error, Equatable {
  /// The user declined the delete confirmation. Copies and originals all remain.
  case userDeclinedDelete
  /// Squishing needs full photo-library access (limited access can't see album membership). Nothing was touched.
  case needsFullAccess
}

/// Squishes in two steps, so the user sees one system prompt for all squished originals.
public protocol SquishRunner: Sendable {
  /// Exports, squishes, creates and verifies a copy of each item. Never touches originals. Honors task cancellation
  /// by stopping and setting `cancelled`.
  func prepare(_ items: [SquishRequest], progress: (@Sendable (SquishRunProgress) -> Void)?) async -> SquishBatch
  /// Deletes all the originals in one change request (one system prompt). Throws `SquishRunnerError.userDeclinedDelete`
  /// when the user declines; nothing is deleted then.
  func commitDeletes(_ prepared: [SquishedCopy]) async throws -> SquishDeletion
  /// Removes leftover copies (failed verification, or a declined delete the user gives up on) with one system prompt.
  func discardCopies(_ newAssetIDs: [String]) async throws
}
