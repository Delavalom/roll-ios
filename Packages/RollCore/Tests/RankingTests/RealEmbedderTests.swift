import CoreGraphics
import Foundation
import ImageIO
import Ranking
import Testing
@testable import Embedding

/// The real EmbeddingGemma model on 20 seed fixtures (spec §11): the Screenshots and Memes prompts must each rank at
/// least 3 of their 4 fixtures in the top 5. Runs only when a converted model is available:
/// `EGCM_MODEL_PATH=/path/to/model swift test --filter RealEmbedderTests`. Fixtures come from the sibling checkout
/// `../embeddinggemma-coreml/fixtures` (or `EGCM_FIXTURES`).
private let realModelPath = ProcessInfo.processInfo.environment["EGCM_MODEL_PATH"]

@Suite(.enabled(if: realModelPath != nil, "set EGCM_MODEL_PATH to run"))
struct RealEmbedderTests {
  static let modelPath = realModelPath

  static var fixtures: URL {
    if let override = ProcessInfo.processInfo.environment["EGCM_FIXTURES"] { return URL(fileURLWithPath: override) }
    // Tests/RankingTests/ → RollCore → Packages → roll-ios → its parent, where the sibling checkout sits.
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("embeddinggemma-coreml/fixtures")
  }

  /// 4 each of the two categories under test, 12 others.
  static let picks: [(category: String, count: Int)] = [
    ("screenshots", 4), ("memes", 4), ("people", 2), ("dogs", 2), ("cats", 2), ("food", 2), ("landscapes", 2),
    ("documents", 2),
  ]

  struct Fixture { let id: String; let category: String; let url: URL }

  static func loadFixtures() throws -> [Fixture] {
    let lines = try String(contentsOf: fixtures.appendingPathComponent("images.jsonl"), encoding: .utf8)
      .split(separator: "\n")
    let rows = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:] }
    var chosen: [Fixture] = []
    for (category, count) in picks {
      let matching = rows.filter { $0["category"] as? String == category }
        .compactMap { row -> Fixture? in
          guard let id = row["id"] as? String, let file = row["file"] as? String else { return nil }
          return Fixture(id: id, category: category, url: fixtures.appendingPathComponent(file))
        }
        .sorted { $0.id < $1.id }
      try #require(matching.count >= count, "only \(matching.count) \(category) fixtures")
      chosen += matching.prefix(count)
    }
    return chosen
  }

  static func image(at url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  @Test func screenshotAndMemePromptsRankTheirFixturesFirst() async throws {
    let embedder = try await GemmaEmbedder.load(source: .file(URL(fileURLWithPath: try #require(Self.modelPath))))
    let fixtures = try Self.loadFixtures()
    #expect(fixtures.count == 20)
    var vectors: [[Float]] = []
    for fixture in fixtures { vectors.append(try await embedder.embed(image: try Self.image(at: fixture.url))) }

    for (prompt, category) in [(Preset.screenshots.prompts[0], "screenshots"), (Preset.memes.prompts[0], "memes")] {
      #expect(prompt == (category == "screenshots" ? "a screenshot of a phone screen" : "a meme with caption text"))
      let query = try await embedder.embed(query: prompt)
      let ranked = zip(fixtures, vectors)
        .map { fixture, v in (fixture, zip(query, v).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
        .sorted { $0.1 > $1.1 }
      let top5 = ranked.prefix(5).map(\.0)
      let hits = top5.filter { $0.category == category }.count
      #expect(hits >= 3, "\"\(prompt)\": top 5 were \(top5.map { "\($0.id) \($0.category)" })")
    }
  }
}
