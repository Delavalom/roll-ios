import Embedding
import Foundation
import Ranking
import Store

/// A library shaped like the founder's phone after the 30k proof (aggregates of the proof database, no identifiers):
/// 29,685 rows, 29,681 embedded at 256 dimensions (the app's `GemmaEmbedder` width), 5,190 videos, 2,532 screenshots,
/// 4,055 `isUtility`, 122 with blur < 25, 2,869 with aesthetic < -0.3, a ~3 KB feature print per row (it sits before
/// `deleted` / `previewSide` in the row, so SQL reads walk it), ids 43 characters long. Vectors are random unit vectors;
/// one in ten lies near one of the presets' prompts, so piles have real matches above the 0.2 floor.
struct SearchBenchWorld {
  static let rows = 29_685
  static let unembedded = 4
  static let dimensions = 256

  let dir: URL
  let repo: Repositories
  let vectors: VectorStore
  let engine: SwipefileEngine
  let ids: [String]

  static func make(rows: Int = rows) async throws -> SearchBenchWorld {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try AppDatabase.open(at: dir.appendingPathComponent("roll.sqlite"))
    let embedder = StubEmbedder(dimensions: dimensions)
    let vectors = try await VectorStore(url: dir.appendingPathComponent("vectors.egix"), dimensions: dimensions,
                                        revision: embedder.revision, database: db)
    let repo = Repositories(db)

    var g = SeededRNG(seed: 30_000)
    var prompts: [[Float]] = []
    for preset in Preset.allCases { for p in preset.prompts { prompts.append(try await embedder.embed(query: p)) } }

    var records: [AssetRecord] = []
    var batch: [(id: String, vector: [Float])] = []
    records.reserveCapacity(rows)
    for i in 0..<rows {
      let id = Self.identifier(using: &g)
      let video = i % 1_000 < 175  // 5,190 of 29,685
      let screenshot = !video && i % 1_000 >= 175 && i % 1_000 < 260  // ~2,532
      let utility = i % 1_000 >= 300 && i % 1_000 < 437  // ~4,055
      let blur: Double = i % 1_000 < 4 ? Double.random(in: 1..<25, using: &g) : Double.random(in: 25...3_000, using: &g)
      let aesthetic: Double = i % 100 >= 90 ? Double.random(in: -1 ..< -0.3, using: &g)
        : Double.random(in: -0.3...1, using: &g)
      let print = Data((0..<3_080).map { _ in UInt8.random(in: 0...255, using: &g) })
      records.append(AssetRecord(
        id: id, mediaType: video ? Preset.videoMediaType : Preset.imageMediaType,
        subtypes: screenshot ? Preset.screenshotSubtype : 0, created: Double(i), pixelW: 4_032, pixelH: 3_024,
        duration: video ? 12 : nil, uti: video ? "com.apple.quicktime-movie" : "public.heic",
        estBytes: video ? Int64.random(in: 5_000_000...400_000_000, using: &g) : Int64.random(in: 1_000_000...6_000_000, using: &g),
        signalsDone: true, blur: blur, aesthetic: aesthetic, isUtility: utility, phash: g.next(), featurePrint: print,
        modified: Double(i), source: i % 6 == 0 ? .preview : .full, previewSide: i < 10 ? 120 : 300))
      guard i >= unembedded else { continue }
      let v = i % 10 == 0 ? near(prompts[i / 10 % prompts.count], using: &g) : randomUnit(dimensions, using: &g)
      batch.append((id, v))
    }
    try await repo.upsertAssets(records)
    await vectors.reserve(batch.count)
    try await vectors.upsert(batch)
    try await vectors.save()
    try await repo.markEmbedded(ids: batch.map(\.id))
    for preset in Preset.allCases { try await repo.save(preset.swipefile(created: 0)) }

    let engine = SwipefileEngine(repositories: repo, vectors: vectors, embedder: embedder)
    return SearchBenchWorld(dir: dir, repo: repo, vectors: vectors, engine: engine, ids: records.map(\.id))
  }

  func cleanUp() { try? FileManager.default.removeItem(at: dir) }

  /// `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/L0/001`, like a PhotoKit local identifier (43 characters).
  private static func identifier(using g: inout SeededRNG) -> String {
    let a = g.next(), b = g.next()
    let hex = String(format: "%016llX%016llX", a, b)
    let c = Array(hex)
    return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))/L0/001"
  }

  /// A unit vector close to `center` (cosine about 0.9).
  private static func near(_ center: [Float], using g: inout SeededRNG) -> [Float] {
    unitVector(zip(center, randomUnit(center.count, using: &g)).map { $0 + 0.45 * $1 })
  }
}
