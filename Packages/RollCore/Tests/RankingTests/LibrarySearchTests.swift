import CoreGraphics
import Embedding
import Foundation
import Ranking
import Store
import Synchronization
import Testing

/// Maps query text to fixed vectors; anything else lands on the "nonsense" axis.
private struct MapEmbedder: Embedder {
  var dimensions = 256
  var revision = "map-v1"
  var map: [String: [Float]] = [:]
  func embed(image: CGImage) async throws -> [Float] { axis(1, dimensions) }
  func embed(query: String) async throws -> [Float] { map[query] ?? axis(1, dimensions) }
}

private func axis(_ i: Int, _ n: Int = 256) -> [Float] {
  var v = [Float](repeating: 0, count: n)
  v[i] = 1
  return v
}

private func mix(_ parts: [(Int, Float)]) -> [Float] {
  var v = [Float](repeating: 0, count: 256)
  for (i, w) in parts { v[i] += w }
  return unitVector(v)
}

/// Axis 0 means "funny meme", axis 1 is where unrelated queries land. Every asset has a private axis
/// of its own; the 120 fillers lean on axis 1 by an evenly spread amount, so an unrelated query scores
/// them evenly and nothing stands out.
private struct Library {
  let repo: Repositories
  let vectors: VectorStore
  let embedder: MapEmbedder
  let dir: URL

  static func make() async throws -> Library {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-search-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try AppDatabase.inMemory()
    let embedder = MapEmbedder(map: ["funny meme": axis(0)])
    let vectors = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: 256,
                                        revision: embedder.revision, database: db)
    let repo = Repositories(db)
    var items: [(String, [Float]?)] = (0..<120).map { i in ("r\(i)", mix([(1, Float(i % 40) / 200), (3 + i, 1)])) }
    items.append(("m", mix([(0, 1), (1, 0.1), (250, 0.2)])))  // the clear match
    items.append(("k", mix([(1, 0.1), (240, 1)])))  // ordinary picture, but its text matches
    items.append(("gone", mix([(0, 1), (241, 0.2)])))  // would match, but deleted
    items.append(("doc", nil))  // live, text only, no vector
    try await repo.upsertAssets(items.map { AssetRecord(id: $0.0, mediaType: 1, subtypes: 0, created: 0, estBytes: 1) })
    let embedded = items.compactMap { item in item.1.map { (id: item.0, vector: $0) } }
    try await vectors.upsert(embedded)
    try await vectors.save()
    try await repo.markEmbedded(ids: embedded.map(\.id))
    try await repo.markDeleted(["gone"])
    return Library(repo: repo, vectors: vectors, embedder: embedder, dir: dir)
  }

  func search(embedder: MapEmbedder? = nil,
              coverage: (@Sendable ([String]) async throws -> [String: Double])? = nil) -> LibrarySearch {
    LibrarySearch(embedder: embedder ?? self.embedder, vectors: vectors, repositories: repo, keywordCoverage: coverage)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

/// Text index stand-in: "boarding pass" is in `k` fully, in `doc` and `gone` partly, in `r0` barely.
private let fakeCoverage: @Sendable ([String]) async throws -> [String: Double] = { terms in
  guard terms == ["boarding", "pass"] else { return [:] }
  return ["k": 1, "doc": 0.5, "gone": 1, "r0": 0.4]
}

struct LibrarySearchTests {
  @Test func aClearMatchIsTheOnlyHit() async throws {
    let library = try await Library.make()
    defer { library.cleanUp() }
    let hits = try await library.search(coverage: fakeCoverage).search("funny meme")
    #expect(hits.map(\.id) == ["m"])  // "gone" scores as high but is deleted
    let hit = try #require(hits.first)
    #expect(try #require(hit.z) >= LibrarySearch.zGate)
    #expect(hit.coverage == 0 && !hit.weak)
    #expect(abs(hit.score - LibrarySearch.fusedScore(z: hit.z, coverage: 0, lookup: false)) < 1e-5)
  }

  @Test func aNonsenseQueryFindsNothing() async throws {
    let library = try await Library.make()
    defer { library.cleanUp() }
    #expect(try await library.search(coverage: fakeCoverage).search("zxqv blorp").isEmpty)
    #expect(try await library.search().search("zxqv blorp").isEmpty)
  }

  @Test func wordsRescueWhatMeaningMisses() async throws {
    let library = try await Library.make()
    defer { library.cleanUp() }
    let seen = Mutex<[[String]]>([])
    let hits = try await library.search(coverage: { terms in
      seen.withLock { $0.append(terms) }
      return try await fakeCoverage(terms)
    }).search("my Boarding pass")
    #expect(seen.withLock { $0 } == [["boarding", "pass"]])
    // k: all the words; doc: half of them and no vector. gone is deleted, r0 has too few words.
    #expect(hits.map(\.id) == ["k", "doc"])
    #expect(hits[0].coverage == 1 && hits[0].z.map { $0 < LibrarySearch.zGate } == true)
    #expect(hits[1].z == nil && hits[1].coverage == 0.5)
    // doc trails far behind k: folded under weaker matches.
    #expect(!hits[0].weak && hits[1].weak)
    #expect(Fold.strongCount(hits.map(\.score)) == 1)
  }

  @Test func withoutATextIndexOnlyMeaningCounts() async throws {
    let library = try await Library.make()
    defer { library.cleanUp() }
    #expect(try await library.search().search("boarding pass").isEmpty)
    #expect(try await library.search().search("funny meme").map(\.id) == ["m"])
  }

  @Test func fusionWeighsLookupsTowardWords() {
    #expect(LibrarySearch.fusedScore(z: 3, coverage: 1, lookup: false) == 3 + 2)
    #expect(LibrarySearch.fusedScore(z: 3, coverage: 1, lookup: true) == 1.5 + 4)
    #expect(LibrarySearch.fusedScore(z: -4, coverage: 0, lookup: false) == 0)
    #expect(LibrarySearch.fusedScore(z: nil, coverage: 0.25, lookup: false) == 2 * 0.125)
  }

  @Test func aLookupQueryRanksItsExactTextFirst() async throws {
    let library = try await Library.make()
    defer { library.cleanUp() }
    var embedder = library.embedder
    // Both queries' vectors lean a little toward the memes, so m stands out (z about 4) for both.
    for text in ["INV2041", "invoice"] { embedder.map[text] = mix([(0, 0.3), (1, 1)]) }
    let search = library.search(embedder: embedder, coverage: { terms in
      terms == ["inv2041"] || terms == ["invoice"] ? ["k": 1] : [:]
    })
    #expect(try await search.search("invoice").map(\.id) == ["m", "k"])  // meaning 1x, words 1x
    #expect(try await search.search("INV2041").map(\.id) == ["k", "m"])  // a code: meaning 0.5x, words 2x
  }

  @Test func blankTextAndLimitAreHonored() async throws {
    let library = try await Library.make()
    defer { library.cleanUp() }
    #expect(try await library.search(coverage: fakeCoverage).search("   ").isEmpty)
    #expect(try await library.search(coverage: fakeCoverage).search("boarding pass", limit: 1).map(\.id) == ["k"])
  }

  @Test func aMismatchedEmbedderThrows() async throws {
    let library = try await Library.make()
    defer { library.cleanUp() }
    await #expect(throws: SwipefileEngine.EngineError.revisionMismatch) {
      try await library.search(embedder: MapEmbedder(revision: "other")).search("funny meme")
    }
    await #expect(throws: SwipefileEngine.EngineError.dimensionMismatch(embedder: 128, index: 256)) {
      try await library.search(embedder: MapEmbedder(dimensions: 128)).search("funny meme")
    }
  }
}
