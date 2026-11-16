import EmbeddingIndex
import FindEvalKit
import Foundation
import GRDB
import Places
import Ranking
import Store

/// Everything a variant can read about the library, loaded once per `pool` run. Private: ids, dates, places.
///
/// - **Vectors**: the phone's index file (`VectorIndex`, read-only: never saved), scored one query text at a time with
///   `VectorIndex.dotAll`, the product `VectorStore.dotAll` wraps (one query per call, as `SwipefileEngine.search`
///   does, so the dot products are bit-for-bit the app's).
/// - **Store**: RollCore's own `Repositories` over a throwaway clone of the database (`AppDatabase` migrates on open,
///   so the private copy itself is never opened for writing). Typed-search reads go through it: `keywordCoverage` (the
///   FTS5 text index, Schema v10; empty on older databases, where the migration creates it empty) and `searchAssets`.
/// - **Pool**: the live, embedded rows that have a vector (the whole-library pool `SwipefileEngine.poolScores` builds).
/// - **Export / vision / labels**: optional phone export (`assets.jsonl`: created, location, albums), Vision labels,
///   and labels so far (e.g. for V5's "more like these" seeds). Empty when not given.
final class FindLibrary {
  let index: VectorIndex
  let qvecs: QueryVectorsFile
  let repositories: Repositories
  let database: AppDatabase
  /// Index ids in `dotAll` order (stable: the index is never written).
  let ids: [String]
  /// Per index row: live and embedded in the database (in the search pool).
  let pooled: [Bool]
  let poolCount: Int
  let export: [String: ExportAsset]
  let vision: [String: VisionLine]
  let labelsDir: URL?
  /// "Now" for refinements and date words: the newest `created` in the export, else the clock.
  let now: Double
  private var cache: [String: [Float]] = [:]
  private let clone: URL

  // Lazily built for the FindSearch variants (`Library+Find.swift`).
  var eventsCache: (assignment: [String: String], tripOf: [String: String], moments: Int, trips: Int)?
  var tagsCache: [Double: TagIndex] = [:]
  var gazetteerCache: Gazetteer??
  var locatedCache: [(latitude: Double, longitude: Double)]?
  /// (variant name, slug) → answer, so a variant can build on another's (V5 on V0) without running it twice.
  var answers: [String: VariantAnswer] = [:]

  init(db: URL, index indexURL: URL, qvecs qvecsURL: URL, export exportURL: URL?, vision visionURL: URL?,
       labels: URL?) async throws {
    qvecs = try JSONOut.read(QueryVectorsFile.self, from: qvecsURL)
    // Throws revisionMismatch unless the query vectors come from the model that built the index.
    index = try VectorIndex(url: indexURL, dimensions: qvecs.dimensions, modelRevision: qvecs.revision)
    ids = index.dotAll([[Float](repeating: 0, count: qvecs.dimensions)]).ids

    clone = FileManager.default.temporaryDirectory.appending(path: "find-eval-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    let dbCopy = clone.appending(path: "roll.sqlite")
    try FileManager.default.copyItem(at: db, to: dbCopy)  // APFS clone: instant, and the source stays untouched
    for suffix in ["-wal", "-shm"] {
      let side = URL(fileURLWithPath: db.path + suffix)
      if FileManager.default.fileExists(atPath: side.path) {
        try FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: dbCopy.path + suffix))
      }
    }
    database = try AppDatabase.open(at: dbCopy)
    repositories = Repositories(database)

    let live = Set(try await repositories.liveEmbeddedIds())
    pooled = ids.map(live.contains)
    poolCount = pooled.filter { $0 }.count

    var export: [String: ExportAsset] = [:]
    if let exportURL { for a in try JSONLines.decode(ExportAsset.self, from: exportURL) { export[a.id] = a } }
    self.export = export
    var vision: [String: VisionLine] = [:]
    if let visionURL { for v in try JSONLines.vision(from: visionURL) { vision[v.id] = v } }
    self.vision = vision
    labelsDir = labels
    now = export.values.compactMap(\.created).max() ?? Date().timeIntervalSince1970
  }

  deinit { try? FileManager.default.removeItem(at: clone) }

  /// Rows of words in the text index (Schema v10; 0 on an older database, where the migration creates it empty).
  func textRows() async throws -> Int {
    try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assetText") ?? 0 }
  }

  /// The unit query vector embedded for exactly `text` (`find-eval embed`).
  func vector(_ text: String) throws -> [Float] {
    guard let v = qvecs.vectors[text] else {
      throw FindSpec.Invalid("no query vector for a text of this query; run embed again with the same specs")
    }
    return v
  }

  /// `text`'s dot product with every stored vector, in `ids` order (one `dotAll` per text, cached).
  func scores(_ text: String) throws -> [Float] {
    if let hit = cache[text] { return hit }
    let s = index.dotAll([try vector(text)]).scores
    cache[text] = s
    return s
  }

  /// `scores(text)` as `VectorStore.dotAll` returns it.
  func dots(_ text: String) throws -> DotProducts {
    DotProducts(ids: ids, queryCount: 1, scores: try scores(text))
  }

  func labels(_ slug: String) throws -> Labels? {
    guard let labelsDir else { return nil }
    return try Labels.load(labelsDir, slug: slug)
  }
}
