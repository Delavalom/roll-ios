import Foundation
import Store

// MARK: - The pool fast path (shared by candidates and typed search)

extension SwipefileEngine {
  /// Reads the live rows and aligns `presets`' pools with the vector index now, so the next search of those piles
  /// skips the SQL read (it still happens again after any ranking-relevant write). Optional; the app can call it once
  /// the engine is attached and indexing is idle.
  public func preparePools(for presets: [Preset]) async throws {
    let (snapshot, _) = try await candidatePool.snapshot()
    guard vectors.dimensions > 0 else { return }
    let dots = try await vectors.dotAll([[Float](repeating: 0, count: vectors.dimensions)])
    for preset in presets where !preset.ranksByBytes {
      _ = await candidatePool.aligned(preset: preset, filter: preset.filter, snapshot: snapshot, dots: dots)
    }
  }

  /// The pool of a pile, or of the whole library (`preset` nil, `filter` `.none`, `decidedIn` nil), aligned with
  /// `queries`' dot products over every stored vector: the fast path `candidates` uses, for typed search to reuse.
  /// Entries are live, embedded assets passing `filter` that have a vector; those decided in `decidedIn` or in
  /// `excluding` are in `skipped`. Rows are read from SQL only after a ranking-relevant write (`CandidatePool`).
  /// The caller makes the queries (same revision and width as the index; `VectorStoreError.unusableQuery` otherwise).
  public func poolScores(queries: [[Float]], preset: Preset?, filter: CandidateFilter, decidedIn swipefileId: String?,
                         excluding: Set<String>) async throws -> PoolScores {
    let clock = ContinuousClock()
    var t = SearchTimings()
    let (snapshot, read) = try await candidatePool.snapshot()
    t.sql = read
    var mark = clock.now
    var decided: [String] = []
    if let swipefileId { decided = try await repositories.decidedAssetIds(swipefileId: swipefileId) }
    t.decisions = clock.now - mark
    mark = clock.now
    let dots = try await vectors.dotAll(queries)
    t.dot = clock.now - mark
    mark = clock.now
    let aligned = await candidatePool.aligned(preset: preset, filter: filter, snapshot: snapshot, dots: dots)
    var skipped = Set<Int>()
    if !decided.isEmpty || !excluding.isEmpty {
      for row in await candidatePool.rows(of: decided + Array(excluding), in: dots) where aligned.entryByRow[row] >= 0 {
        skipped.insert(Int(aligned.entryByRow[row]))
      }
    }
    t.poolCount = aligned.rows.count - skipped.count
    t.pool = clock.now - mark
    return PoolScores(boosts: aligned.boosts, dots: dots, skipped: skipped, timings: t, rows: aligned.rows,
                      source: aligned.source, snapshot: snapshot.rows)
  }
}
