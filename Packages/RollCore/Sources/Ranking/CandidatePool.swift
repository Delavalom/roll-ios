import Foundation
import Store

/// Every live asset row ranking needs, kept in memory between searches, plus each pile's pool aligned with the vector
/// index as integers (`SwipefileEngine.candidates` / `poolScores`).
///
/// **Rows** are stamped with `RankingChanges.generation` read **before** the SQL read, and re-read when it moved: any
/// committed insert, delete, or update of a ranking column of `asset` (new signals, `embedded`, `deleted`, library
/// metadata). A write racing the read only costs one more read. **Aligned pools** are keyed by (preset, filter) and
/// valid for one rows generation and one `VectorStore.layout` (the order of `dotAll`'s rows). **Decisions** are not
/// cached: the engine reads them per call (a primary-key range) and skips them by row.
actor CandidatePool {
  struct Snapshot: Sendable {
    var generation: UInt64
    var rows: [RankingRow]
  }

  /// One pile's pool: per entry its row in the dot products (Float, for `vDSP_vindex`), boost, and snapshot index;
  /// `entryByRow` maps a dot row back to its entry (-1: not in the pool).
  struct Aligned: Sendable {
    var rows: [Float]
    var boosts: [Float]
    var source: [Int32]
    var entryByRow: [Int32]
  }

  private struct AlignedEntry {
    var preset: Preset?
    var filter: CandidateFilter
    var generation: UInt64
    var layout: UInt64
    var pool: Aligned
  }

  private static let maxAligned = 16

  private let repositories: Repositories
  private var changes: Task<RankingChanges, any Error>?
  private var cached: Snapshot?
  private var rowByID: (layout: UInt64, count: Int, map: [String: Int32])?
  private var aligned: [AlignedEntry] = []

  init(repositories: Repositories) {
    self.repositories = repositories
  }

  /// The live rows, and how long the SQL read took (zero when the cached rows were current).
  func snapshot() async throws -> (snapshot: Snapshot, read: Duration) {
    let generation = try await observer().generation
    if let cached, cached.generation == generation { return (cached, .zero) }
    let start = ContinuousClock.now
    let snapshot = Snapshot(generation: generation, rows: try await repositories.rankingRows())
    let read = ContinuousClock.now - start
    if (cached?.generation ?? 0) <= generation { cached = snapshot }
    return (snapshot, read)
  }

  /// The pool of `preset` / `filter` in `snapshot`, aligned with `dots` (built once per generation and layout):
  /// embedded rows that pass `filter` and have a vector in `dots`. A row flagged embedded whose vector is missing
  /// (not reconciled yet) has no score, so it is left out instead of riding in on its boost.
  func aligned(preset: Preset?, filter: CandidateFilter, snapshot: Snapshot, dots: DotProducts) -> Aligned {
    if let hit = aligned.first(where: { $0.preset == preset && $0.filter == filter
                                        && $0.generation == snapshot.generation && $0.layout == dots.layout }) {
      return hit.pool
    }
    let map = rowMap(dots)
    var pool = Aligned(rows: [], boosts: [], source: [], entryByRow: [Int32](repeating: -1, count: dots.ids.count))
    pool.rows.reserveCapacity(snapshot.rows.count)
    pool.boosts.reserveCapacity(snapshot.rows.count)
    pool.source.reserveCapacity(snapshot.rows.count)
    for (i, row) in snapshot.rows.enumerated() where row.embedded && filter.matches(row.asset) {
      guard let r = map[row.asset.id] else { continue }
      pool.entryByRow[Int(r)] = Int32(pool.rows.count)
      pool.rows.append(Float(r))
      pool.boosts.append(preset?.signalBoost(row.asset) ?? 0)
      pool.source.append(Int32(i))
    }
    aligned.removeAll { $0.generation != snapshot.generation || $0.layout != dots.layout }
    if aligned.count >= Self.maxAligned { aligned.removeFirst() }
    aligned.append(AlignedEntry(preset: preset, filter: filter, generation: snapshot.generation, layout: dots.layout,
                                pool: pool))
    return pool
  }

  /// `dots`' row of each of `ids` that has a vector (call after `aligned` for the same `dots`).
  func rows(of ids: some Sequence<String>, in dots: DotProducts) -> [Int] {
    let map = rowMap(dots)
    return ids.compactMap { map[$0].map(Int.init) }
  }

  /// id → row of `dots`, built once per layout.
  private func rowMap(_ dots: DotProducts) -> [String: Int32] {
    if let rowByID, rowByID.layout == dots.layout, rowByID.count == dots.ids.count { return rowByID.map }
    var map: [String: Int32] = [:]
    map.reserveCapacity(dots.ids.count)
    for (r, id) in dots.ids.enumerated() { map[id] = Int32(r) }
    rowByID = (dots.layout, dots.ids.count, map)
    return map
  }

  /// One observer for the life of the pool, registered before the first read (concurrent first calls share it).
  private func observer() async throws -> RankingChanges {
    if let changes { return try await changes.value }
    let repositories = repositories
    let task = Task { try await repositories.observeRankingChanges() }
    changes = task
    do { return try await task.value } catch { changes = nil; throw error }
  }
}
