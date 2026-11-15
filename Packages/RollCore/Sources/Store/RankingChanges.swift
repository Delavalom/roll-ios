import GRDB
import Synchronization

/// A counter of committed transactions that changed anything ranking reads from `asset`: an inserted or removed row,
/// or an update of one of `Repositories.rankingColumns`. An in-memory candidate pool stamped with the generation read
/// **before** its SQL read is current while the generation is unchanged. Updates of other columns (locality, type
/// lookups, attempts) and rolled-back transactions leave it alone, and so do decisions (ranking reads those per call).
///
/// GRDB calls it on the writer's queue after each commit, so every writer of this database is seen as long as it goes
/// through GRDB (the app has one writer). Get one from `Repositories.observeRankingChanges()`; it observes for as long
/// as it is alive.
public final class RankingChanges: TransactionObserver, Sendable {
  private struct State {
    var generation: UInt64 = 0
    var pending = false
    var tagGeneration: UInt64 = 0
    var pendingTags = false
  }

  private let state = Mutex(State())
  private static let table = "asset"
  private static let tagTables: Set<String> = ["assettag", "assettagread"]
  private static let columns = Set(Repositories.rankingColumns.map { $0.lowercased() })

  init() {}

  /// Goes up by at least 1 after every commit that changed what ranking reads.
  public var generation: UInt64 { state.withLock { $0.generation } }

  /// Goes up by at least 1 after every commit that changed the scene labels (`assetTag`, `assetTagRead`), counted
  /// apart so the tag pass's writes don't make the candidate rows be read again.
  public var tagGeneration: UInt64 { state.withLock { $0.tagGeneration } }

  public func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    switch eventKind {
    case .insert(let table), .delete(let table):
      table.lowercased() == Self.table || Self.tagTables.contains(table.lowercased())
    case .update(let table, let columns):
      (table.lowercased() == Self.table && columns.contains { Self.columns.contains($0.lowercased()) })
        || Self.tagTables.contains(table.lowercased())
    }
  }

  public func databaseDidChange(with event: DatabaseEvent) {
    let tags = Self.tagTables.contains(event.tableName.lowercased())
    state.withLock { if tags { $0.pendingTags = true } else { $0.pending = true } }
  }

  public func databaseDidCommit(_ db: Database) {
    state.withLock {
      if $0.pending { $0.generation &+= 1 }
      if $0.pendingTags { $0.tagGeneration &+= 1 }
      $0.pending = false
      $0.pendingTags = false
    }
  }

  public func databaseDidRollback(_ db: Database) {
    state.withLock { $0.pending = false; $0.pendingTags = false }
  }
}
