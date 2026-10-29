import Commit
import Foundation
import Squish
import Store
import Synchronization

/// The verified copies prepared so far, by copy id. `SquishedCopy` (Commit's view) drops the fingerprints that
/// `ReplaceFlow.commitDeletes` re-checks, so the runner keeps the full `Prepared` here. Share one registry between
/// runners so a copy prepared (or reconciled) by one can be committed by another.
public final class PreparedRegistry: Sendable {
  private let items = Mutex<[String: Prepared]>([:])

  public init() {}

  func add(_ prepared: [Prepared]) { items.withLock { for p in prepared { $0[p.newAssetID] = p } } }
  func remove(copyIDs: [String]) { items.withLock { for id in copyIDs { $0[id] = nil } } }
  func get(_ copyID: String) -> Prepared? { items.withLock { $0[copyID] } }
}

/// What `reconcile()` found on launch, in Commit's terms.
public struct SquishRecovery: Sendable, Equatable {
  /// Verified copies whose originals are still there: finish them (delete the originals) or discard the copies.
  public var pending: [SquishedCopy] = []
  /// Copies that exist but were never verified: discard them.
  public var orphanCopyIDs: [String] = []

  public init(pending: [SquishedCopy] = [], orphanCopyIDs: [String] = []) {
    self.pending = pending; self.orphanCopyIDs = orphanCopyIDs
  }

  public var isEmpty: Bool { pending.isEmpty && orphanCopyIDs.isEmpty }
}

/// `ReplaceFlow` behind Commit's `SquishRunner` seam:
/// - `SquishRequest` → `SquishItem` with this runner's "Keep 4K" choice;
/// - `PrepareReport` → `SquishBatch` (`Prepared` → `SquishedCopy`; a failed verification's leftover copy becomes
///   `leftoverCopyID`);
/// - `SquishCommitResult` → `SquishDeletion` (skipped pairs keep their originals);
/// - `ReplaceError.userDeclinedDelete` → `SquishRunnerError.userDeclinedDelete` and `ReplaceError.needsFullAccess` →
///   `SquishRunnerError.needsFullAccess` (thrown, or as each failure's error from `prepare`). Other failures keep
///   their `ReplaceError`, which `SquishRefusal.classify` turns into UI text.
public struct ReplaceFlowRunner: SquishRunner {
  private let flow: ReplaceFlow
  public let keep4K: Bool
  private let registry: PreparedRegistry
  #if DEBUG
  private var qaGate: (any QAScopeGate)?
  private var qaHooks = QASquishHooks()
  #endif

  public init(flow: ReplaceFlow, keep4K: Bool = false, registry: PreparedRegistry = PreparedRegistry()) {
    self.flow = flow
    self.keep4K = keep4K
    self.registry = registry
  }

  #if DEBUG
  /// DEBUG device QA (`-QAAlbum`): this runner with `gate` checked right before every squish, original delete and copy
  /// removal (a refused batch changes nothing), plus identifier-free observers.
  public func qaScoped(gate: any QAScopeGate, hooks: QASquishHooks = QASquishHooks()) -> ReplaceFlowRunner {
    var runner = self
    runner.qaGate = gate
    runner.qaHooks = hooks
    return runner
  }
  #endif

  public func prepare(_ items: [SquishRequest], progress: (@Sendable (SquishRunProgress) -> Void)?) async -> SquishBatch {
    #if DEBUG
    if let qaGate {
      do { try await qaGate.check(items.map(\.assetID), for: .squish) } catch {
        return SquishBatch(failures: items.map { SquishFailure(assetID: $0.assetID, error: error) })
      }
    }
    #endif
    let squishItems = items.map { SquishItem(assetID: $0.assetID, estimatedBytes: $0.estimatedBytes, keep4K: keep4K) }
    let report = await flow.prepare(squishItems) { update in
      progress?(SquishRunProgress(assetID: update.assetID, stage: Self.stage(update.phase), fraction: update.fraction))
    }
    #if DEBUG
    qaHooks.prepared?(report)
    #endif
    registry.add(report.prepared)
    let failures = report.failures.map { failure in
      var leftover: String?
      if case let .verificationFailed(_, id) = failure.error { leftover = id }
      return SquishFailure(assetID: failure.assetID, error: Self.map(failure.error), leftoverCopyID: leftover)
    }
    return SquishBatch(prepared: report.prepared.map(Self.copy), failures: failures, cancelled: report.cancelled)
  }

  public func commitDeletes(_ prepared: [SquishedCopy]) async throws -> SquishDeletion {
    var known: [Prepared] = [], unknown: [SquishedCopy] = []
    for copy in prepared {
      if let full = registry.get(copy.newAssetID) { known.append(full) } else { unknown.append(copy) }
    }
    guard !known.isEmpty else { return SquishDeletion(deleted: [], skipped: [], unregistered: unknown) }
    #if DEBUG
    await qaHooks.beforeCommitDeletes?(known.count)
    if let qaGate { try await qaGate.check(known.map(\.assetID), for: .deleteSquishedOriginal) }
    #endif
    let result: SquishCommitResult
    do {
      result = try await flow.commitDeletes(known)
    } catch let error as ReplaceError {
      #if DEBUG
      qaHooks.committed?(.failure(error))
      #endif
      throw Self.map(error)
    }
    #if DEBUG
    qaHooks.committed?(.success(result))
    #endif
    registry.remove(copyIDs: result.deleted.map(\.newAssetID))
    return SquishDeletion(deleted: result.deleted.map(Self.copy),
                          skipped: result.skipped.map { Self.copy($0.prepared) }, unregistered: unknown)
  }

  public func discardCopies(_ newAssetIDs: [String]) async throws {
    #if DEBUG
    if let qaGate { try await qaGate.check(newAssetIDs, for: .discardCopy) }
    #endif
    do {
      try await flow.discardCopies(newAssetIDs)
    } catch let error as ReplaceError {
      throw Self.map(error)
    }
    registry.remove(copyIDs: newAssetIDs)
  }

  /// Settles the squish journal (`ReplaceFlow.reconcile()`); run on launch. Pending pairs are registered, so
  /// `PhotoKitCommitter.retrySquishDeletes` can finish them through this runner. Throws
  /// `SquishRunnerError.needsFullAccess` in limited mode.
  public func reconcile() async throws -> SquishRecovery {
    let found: JournalReconciliation
    do {
      found = try await flow.reconcile()
    } catch let error as ReplaceError {
      throw Self.map(error)
    }
    registry.add(found.pending)
    return SquishRecovery(pending: found.pending.map(Self.copy), orphanCopyIDs: found.orphans.map(\.newAssetID))
  }

  static func copy(_ p: Prepared) -> SquishedCopy {
    SquishedCopy(assetID: p.assetID, newAssetID: p.newAssetID, originalBytes: p.originalBytes, newBytes: p.newBytes)
  }

  static func stage(_ phase: SquishPhase) -> SquishStage {
    switch phase {
    case .downloading: .downloading
    case .encoding: .encoding
    case .verifying: .verifying
    case .saving: .saving
    }
  }

  static func map(_ error: ReplaceError) -> any Error {
    switch error {
    case .userDeclinedDelete: SquishRunnerError.userDeclinedDelete
    case .needsFullAccess: SquishRunnerError.needsFullAccess
    default: error
    }
  }
}
