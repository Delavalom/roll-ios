import Foundation
import Synchronization
import Entitlements
@testable import Commit

/// Ordered record of every library-visible call, shared by the fake library and the fake squish runner.
final class CallLog: Sendable {
  private let events = Mutex<[String]>([])
  func append(_ e: String) { events.withLock { $0.append(e) } }
  var all: [String] { events.withLock { $0 } }
}

struct TestError: Error, Equatable {}

enum Scripted: Sendable { case succeed, userCancel, fail }

/// The PhotoKit seam, scripted by call number (0-based, across deletes and album adds).
final class FakeLibrary: CommitLibrary {
  let log: CallLog
  private let script: Mutex<[Int: Scripted]>
  private let count = Mutex(0)
  private let _deletes = Mutex<[[String]]>([])
  private let _albums = Mutex<[(String, [String])]>([])

  init(log: CallLog = CallLog(), script: [Int: Scripted] = [:]) {
    self.log = log; self.script = Mutex(script)
  }

  var deleteCalls: [[String]] { _deletes.withLock { $0 } }
  var albumCalls: [(String, [String])] { _albums.withLock { $0 } }

  private func next() throws {
    let n = count.withLock { c -> Int in defer { c += 1 }; return c }
    switch script.withLock({ $0[n] }) ?? .succeed {
    case .succeed: return
    case .userCancel: throw CommitLibraryError.userCancelled
    case .fail: throw TestError()
    }
  }

  func delete(_ ids: [String]) async throws {
    log.append("delete:\(ids.count)")
    try next()
    _deletes.withLock { $0.append(ids) }
  }

  func addToAlbum(named name: String, _ ids: [String]) async throws {
    log.append("album:\(name):\(ids.count)")
    try next()
    _albums.withLock { $0.append((name, ids)) }
  }
}

/// Stands in for Squish's `ReplaceFlow`.
final class FakeSquishRunner: SquishRunner {
  let log: CallLog
  /// Asset ids whose prepare fails.
  let failing: Set<String>
  /// Asset ids whose copy vanishes before `commitDeletes`.
  let vanishing: Set<String>
  let cancelPrepare: Bool
  let commit: Scripted
  private let _prepared = Mutex<[[SquishRequest]]>([])
  private let _committed = Mutex<[[SquishedCopy]]>([])

  init(log: CallLog, failing: Set<String> = [], vanishing: Set<String> = [], cancelPrepare: Bool = false,
       commit: Scripted = .succeed) {
    self.log = log; self.failing = failing; self.vanishing = vanishing
    self.cancelPrepare = cancelPrepare; self.commit = commit
  }

  var prepareCalls: [[SquishRequest]] { _prepared.withLock { $0 } }
  var commitCalls: [[SquishedCopy]] { _committed.withLock { $0 } }

  static func copy(_ id: String) -> SquishedCopy {
    SquishedCopy(assetID: id, newAssetID: "new-" + id, originalBytes: 1_000, newBytes: 400)
  }

  func prepare(_ items: [SquishRequest], progress: (@Sendable (SquishRunProgress) -> Void)?) async -> SquishBatch {
    log.append("squish.prepare:\(items.count)")
    _prepared.withLock { $0.append(items) }
    var batch = SquishBatch()
    for (i, item) in items.enumerated() {
      if cancelPrepare && i == 1 { batch.cancelled = true; break }
      progress?(SquishRunProgress(assetID: item.assetID, stage: .encoding, fraction: nil))
      if failing.contains(item.assetID) {
        batch.failures.append(SquishFailure(assetID: item.assetID, error: TestError(), leftoverCopyID: "left-" + item.assetID))
      } else {
        batch.prepared.append(Self.copy(item.assetID))
      }
    }
    return batch
  }

  func commitDeletes(_ prepared: [SquishedCopy]) async throws -> SquishDeletion {
    log.append("squish.commit:\(prepared.count)")
    _committed.withLock { $0.append(prepared) }
    switch commit {
    case .succeed: break
    case .userCancel: throw SquishRunnerError.userDeclinedDelete
    case .fail: throw TestError()
    }
    return SquishDeletion(deleted: prepared.filter { !vanishing.contains($0.assetID) },
                          skipped: prepared.filter { vanishing.contains($0.assetID) })
  }

  func discardCopies(_ newAssetIDs: [String]) async throws {
    log.append("squish.discard:\(newAssetIDs.count)")
  }
}

struct FixedPro: ProStatus {
  let value: Bool
  var isPro: Bool { get async { value } }
}

final class ProgressLog: Sendable {
  private let events = Mutex<[CommitProgress]>([])
  func append(_ e: CommitProgress) { events.withLock { $0.append(e) } }
  var all: [CommitProgress] { events.withLock { $0 } }
}
