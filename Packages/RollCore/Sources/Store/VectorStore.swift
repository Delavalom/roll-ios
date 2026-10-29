import EmbeddingIndex
import Foundation

public enum VectorStoreError: Error, Equatable {
  /// The query at this position has the wrong width or contains NaN / infinity.
  case unusableQuery(Int)
}

/// `VectorStore.dotAll` output: `ids[r]`'s dot product with query `q` is `self[r, q]`.
public struct DotProducts: Sendable {
  /// One per stored vector, in the index's slot order (stable while no id is added or removed).
  public let ids: [String]
  public let queryCount: Int
  /// Query-major, `queryCount x ids.count`: query `q`'s scores are `scores[q * ids.count ..< (q + 1) * ids.count]`.
  public let scores: [Float]
  /// `VectorStore.layout` when this was computed: two results of one store with the same layout have the same `ids`
  /// in the same order, so rows can be cached as integers.
  public let layout: UInt64

  public init(ids: [String], queryCount: Int, scores: [Float], layout: UInt64 = 0) {
    self.ids = ids; self.queryCount = queryCount; self.scores = scores; self.layout = layout
  }

  public subscript(row: Int, query: Int) -> Float { scores[query * ids.count + row] }

  /// Query `q`'s scores, aligned with `ids`.
  public func scores(forQuery q: Int) -> ArraySlice<Float> {
    scores[(q * ids.count)..<((q + 1) * ids.count)]
  }
}

/// Owns the on-disk vector index. `VectorIndex` is a non-Sendable class, so it lives only
/// inside this actor and is reached through these async methods.
///
/// **Commit order (required).** The vector file and the `asset.embedded` flags live in two
/// stores that can't be written atomically, so always write in this order:
///
/// 1. `upsert` the vectors,
/// 2. `save()` the vector file,
/// 3. `Repositories.markEmbedded(ids:)`.
///
/// A crash after step 2 leaves vectors with no flag, which only means re-embedding the same
/// assets later. A crash before step 2 loses vectors that no flag claims. The reverse order
/// could leave flags claiming vectors that don't exist. `reconcile()` repairs that case
/// anyway (and removes vectors no live, flagged row claims), and runs on every open.
public actor VectorStore {
  public nonisolated let dimensions: Int
  public nonisolated let revision: String
  /// True when opening discarded a stale index (model revision or dimensions changed, or the
  /// file was unreadable) and cleared `asset.embedded`, so everything must be re-embedded.
  public nonisolated let didReset: Bool

  private let index: VectorIndex
  private let repositories: Repositories

  /// Opens the index at `url`. If the file was written for another model revision (or is
  /// unusable), clears `asset.embedded` for all rows, deletes the file, and starts empty.
  /// The database is reset first, so a crash in between leaves a stale file that is
  /// discarded again on the next launch. Finishes with `reconcile()`.
  public init(url: URL, dimensions: Int, revision: String, database: AppDatabase) async throws {
    let repositories = Repositories(database)
    var didReset = false
    var opened: VectorIndex
    do {
      opened = try VectorIndex(url: url, dimensions: dimensions, modelRevision: revision)
    } catch let error as VectorIndexError where Self.isStale(error) {
      try await repositories.resetEmbedded()
      try FileManager.default.removeItem(at: url)
      opened = try VectorIndex(url: url, dimensions: dimensions, modelRevision: revision)
      didReset = true
    }
    self.index = opened
    self.repositories = repositories
    self.dimensions = dimensions
    self.revision = revision
    self.didReset = didReset
    Self.removeStaleTempFiles(for: url)
    try await reconcile()
  }

  private static func isStale(_ error: VectorIndexError) -> Bool {
    switch error {
    case .revisionMismatch, .dimensionMismatch, .corrupt, .unsupportedVersion: true
    case .invalidDimensions: false
    }
  }

  /// `<base>/Roll/Index/vectors.egix`; `base` defaults to Application Support. The folder is created
  /// if needed and excluded from backups: the index is derived data that can be rebuilt from the photo
  /// library. The flag lives on the folder, so it covers every atomic-save replacement and temp file.
  public static func defaultURL(in base: URL? = nil) throws -> URL {
    var folder = try rollSupportDirectory(in: base).appendingPathComponent("Index", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? folder.setResourceValues(values)  // best effort
    return folder.appendingPathComponent("vectors.egix")
  }

  /// A killed save can leave `.vectors.egix.<uuid>.tmp` next to the index; remove them on open.
  private static func removeStaleTempFiles(for url: URL) {
    let folder = url.deletingLastPathComponent()
    let prefix = ".\(url.lastPathComponent)."
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  public var count: Int { index.count }

  /// Changes whenever a vector may have been added or removed (every `upsert` / `remove` call; updating an existing
  /// id keeps its slot, but counting it too keeps this simple). `dotAll`'s row order is the same while it holds.
  public private(set) var layout: UInt64 = 0

  /// Makes the flags and the index agree, in both directions; runs on every open. Returns how many
  /// flags were cleared (see `reconcileReport()` for the vector side too).
  @discardableResult
  public func reconcile() async throws -> Int {
    try await reconcileReport().clearedFlags
  }

  /// 1. Clears `asset.embedded` on rows that claim a vector the index doesn't have.
  /// 2. Clears it on deleted rows (their vector goes in step 3).
  /// 3. Removes vectors that no live, flagged row claims: an id whose flag was cleared (a crash between
  ///    clearing the flag and saving, or a content edit while no store was attached), a deleted asset,
  ///    or no row at all. Saves if anything was removed.
  /// Flags are always cleared before vectors are removed, so a crash part-way leaves at worst a vector
  /// with no flag, which the next reconcile removes.
  ///
  /// Only call this while nothing is writing vectors (it runs on open, before anyone has the store): a
  /// flush between its `save()` and `markEmbedded` briefly holds vectors with no flag, and step 3 would
  /// remove them.
  @discardableResult
  public func reconcileReport() async throws -> ReconcileReport {
    let flagged = try await repositories.embeddedIds()
    let missing = flagged.filter { index.vector(for: $0) == nil }
    var cleared = try await repositories.clearEmbedded(ids: missing)
    cleared += try await repositories.clearEmbedded(ids: try await repositories.deletedEmbeddedIds())

    let claimed = Set(try await repositories.liveEmbeddedIds())
    let orphans = storedIds().filter { !claimed.contains($0) }
    if !orphans.isEmpty {
      try remove(ids: orphans)
      try save()
    }
    return ReconcileReport(clearedFlags: cleared, removedVectors: orphans.count)
  }

  /// Every id in the index. `EmbeddingIndex` has no enumeration API, so this is an exhaustive search
  /// with a zero query (every score is 0, nothing is filtered out).
  private func storedIds() -> [String] {
    let n = index.count
    guard n > 0 else { return [] }
    return index.search([Float](repeating: 0, count: dimensions), k: n).map(\.id)
  }

  /// Call with the expected total before bulk indexing, so storage grows once.
  public func reserve(_ expectedCount: Int) {
    index.reserveCapacity(expectedCount)
  }

  public func upsert(id: String, vector: [Float]) throws {
    defer { layout &+= 1 }
    try index.upsert(id: id, vector: vector)
  }

  /// Adds all of `batch`, or none if any vector has the wrong length.
  public func upsert(_ batch: [(id: String, vector: [Float])]) throws {
    for item in batch where item.vector.count != dimensions {
      throw VectorIndexError.dimensionMismatch(expected: dimensions, found: item.vector.count)
    }
    defer { layout &+= 1 }
    for item in batch { try index.upsert(id: item.id, vector: item.vector) }
  }

  public func remove(id: String) throws {
    defer { layout &+= 1 }
    try index.remove(id: id)
  }

  /// Removes every id in `ids`; unknown ids are ignored. Clear the `embedded` flags first, then remove,
  /// then `save()`: a crash in between leaves at worst a vector with no flag.
  public func remove(ids: [String]) throws {
    defer { layout &+= 1 }
    for id in ids { try index.remove(id: id) }
  }

  public func search(_ query: [Float], k: Int, filter: (@Sendable (String) -> Bool)? = nil) -> [(id: String, score: Float)] {
    index.search(query, k: k, filter: filter)
  }

  /// `query · v` for every stored vector and every query, unsorted: what ranking needs to score
  /// the whole library against several prompts (or a classifier) in one call. For unit vectors
  /// (what the embedders produce) the scores are cosines. One matrix product (`VectorIndex.dotAll`).
  ///
  /// Throws `unusableQuery(i)` if query `i` has the wrong width or a NaN / infinity.
  public func dotAll(_ queries: [[Float]]) throws -> DotProducts {
    for (i, q) in queries.enumerated() where q.count != dimensions || !q.allSatisfy(\.isFinite) {
      throw VectorStoreError.unusableQuery(i)
    }
    guard !queries.isEmpty, index.count > 0 else {
      return DotProducts(ids: [], queryCount: queries.count, scores: [], layout: layout)
    }
    let bulk = index.dotAll(queries)
    return DotProducts(ids: bulk.ids, queryCount: bulk.queryCount, scores: bulk.scores, layout: layout)
  }

  public func vector(for id: String) -> [Float]? {
    index.vector(for: id)
  }

  /// Writes the file atomically. Do this before marking assets embedded (see the type docs).
  public func save() throws {
    try index.save()
  }
}

/// What `VectorStore.reconcileReport()` repaired.
public struct ReconcileReport: Sendable, Equatable {
  /// `asset.embedded` flags cleared (no vector, or the asset is deleted).
  public var clearedFlags: Int
  /// Vectors removed because no live, flagged row claims them.
  public var removedVectors: Int

  public init(clearedFlags: Int, removedVectors: Int) {
    self.clearedFlags = clearedFlags; self.removedVectors = removedVectors
  }
}
