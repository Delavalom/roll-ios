import CoreGraphics
import Embedding
import Foundation
import Ranking
import Store
import Synchronization
import Testing

// Shared fixtures of the SwipefileEngine test files.


/// Holds `embed(query:)` callers until opened, and lets a test wait for a condition on how many
/// callers arrived and whether the test's own background work finished.
actor Gate {
  private var isOpen = false
  private var blocked: [CheckedContinuation<Void, Never>] = []
  private var watchers: [(condition: @Sendable (Int, Bool) -> Bool, resume: CheckedContinuation<Void, Never>)] = []
  private(set) var entered = 0
  private var done = false

  func pass() async {
    entered += 1
    notify()
    guard !isOpen else { return }
    await withCheckedContinuation { blocked.append($0) }
  }

  func markDone() { done = true; notify() }

  func wait(until condition: @escaping @Sendable (_ entered: Int, _ done: Bool) -> Bool) async {
    if condition(entered, done) { return }
    await withCheckedContinuation { watchers.append((condition, $0)) }
  }

  func open() {
    isOpen = true
    blocked.forEach { $0.resume() }
    blocked = []
  }

  private func notify() {
    let ready = watchers.filter { $0.condition(entered, done) }
    watchers.removeAll { $0.condition(entered, done) }
    ready.forEach { $0.resume.resume() }
  }
}

/// Counts `embed(query:)` calls so the prompt cache can be checked. `revisionOverride` simulates
/// an embedder that no longer matches the index; `gate` holds query embeds until opened.
final class CountingEmbedder: Embedder {
  let inner = StubEmbedder()
  let calls = Mutex(0)
  let revisionOverride = Mutex<String?>(nil)
  let gate = Mutex<Gate?>(nil)
  var dimensions: Int { inner.dimensions }
  var revision: String { revisionOverride.withLock { $0 } ?? inner.revision }
  func embed(image: CGImage) async throws -> [Float] { try await inner.embed(image: image) }
  func embed(query: String) async throws -> [Float] {
    calls.withLock { $0 += 1 }
    if let gate = gate.withLock({ $0 }) { await gate.pass() }
    return try await inner.embed(query: query)
  }
}

/// An in-memory store plus a vector index in a temp folder, filled per test.
struct World {
  let repo: Repositories
  let vectors: VectorStore
  let embedder: CountingEmbedder
  let engine: SwipefileEngine
  let dir: URL

  static func make() async throws -> World {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-ranking-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try AppDatabase.inMemory()
    let embedder = CountingEmbedder()
    let vectors = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: embedder.dimensions,
                                        revision: embedder.revision, database: db)
    let repo = Repositories(db)
    let clock = Mutex(0.0)
    let engine = SwipefileEngine(repositories: repo, vectors: vectors, embedder: embedder,
                                 now: { clock.withLock { $0 += 1; return $0 } })
    return World(repo: repo, vectors: vectors, embedder: embedder, engine: engine, dir: dir)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: dir) }

  /// Adds assets with vectors, following the commit order (vectors first, then the flag).
  func add(_ items: [(record: AssetRecord, vector: [Float]?)]) async throws {
    try await repo.upsertAssets(items.map(\.record))
    let embedded = items.compactMap { item in item.vector.map { (id: item.record.id, vector: $0) } }
    try await vectors.upsert(embedded)
    try await repo.markEmbedded(ids: embedded.map(\.id))
  }
}

func photo(_ id: String, mediaType: Int = Preset.imageMediaType, bytes: Int64 = 1_000) -> AssetRecord {
  AssetRecord(id: id, mediaType: mediaType, subtypes: 0, created: 0, estBytes: bytes)
}

/// A unit vector close to `center` (cosine about 0.9).
func near(_ center: [Float], using g: inout SeededRNG) -> [Float] {
  unitVector(zip(center, randomUnit(center.count, using: &g)).map { $0 + 0.45 * $1 })
}

func customPile(_ id: String = "sf", prompts: [String], examples: [String] = []) -> SwipefileRecord {
  SwipefileRecord(id: id, name: id, kind: .custom, prompts: prompts, examples: examples, action: .delete, created: 0)
}

/// 300 synthetic images: m0..m29 sit near the prompt vector, r0..r269 are random (cosine near 0). Matches are
/// 10 % of the index, so they stand out on the query's own scale (`QueryScale`: a pile matching a third of the
/// library wouldn't).
func memesWorld(seed: UInt64 = 1) async throws -> (World, SwipefileRecord, matching: Set<String>) {
  let world = try await World.make()
  let sf = customPile(prompts: ["a funny meme"])
  try await world.repo.save(sf)
  let prompt = try await StubEmbedder().embed(query: "a funny meme")
  var g = SeededRNG(seed: seed)
  var items: [(record: AssetRecord, vector: [Float]?)] = []
  for i in 0..<30 { items.append((photo("m\(i)"), near(prompt, using: &g))) }
  for i in 0..<270 { items.append((photo("r\(i)"), randomUnit(256, using: &g))) }
  try await world.add(items)
  return (world, sf, Set((0..<30).map { "m\($0)" }))
}
