import Foundation
import Testing
import EmbeddingGemma
@testable import Embedding

/// Runs only when a converted model is available locally: `EGCM_MODEL_PATH=/path/to/model swift test`.
private let modelPath = ProcessInfo.processInfo.environment["EGCM_MODEL_PATH"]

struct GemmaEmbedderTests {
  @Test(.enabled(if: modelPath != nil, "set EGCM_MODEL_PATH to run"))
  func embedsQueryWithRealModel() async throws {
    let embedder = try await GemmaEmbedder.load(source: .file(URL(fileURLWithPath: modelPath!)))
    #expect(embedder.dimensions == 256)
    let v = try await embedder.embed(query: "a screenshot of a phone screen")
    #expect(v.count == 256)
    #expect(abs(norm(v) - 1) < 1e-3)
  }

  @Test func budgetComesFromThePackage() {
    // `.auto` is the package's device tier (280 on A17 Pro and newer and on Macs, 70 otherwise; tested there).
    #expect(GemmaEmbedder.imageTokens(for: .auto) == EmbeddingGemma.ImageBudget.auto.resolved)
    #expect(GemmaEmbedder.imageTokens(for: .tokens70) == 70)
    #expect(GemmaEmbedder.imageTokens(for: .tokens280) == 280)
  }

  @Test func revisionIncludesTheBudgetSoMixingBudgetsInvalidatesTheIndex() {
    #expect(GemmaEmbedder.makeRevision(modelRevision: "abc123", budgetTokens: 70) == "abc123-b70")
    #expect(GemmaEmbedder.makeRevision(modelRevision: "abc123", budgetTokens: 280) == "abc123-b280")
  }

  #if DEBUG
  @Test func developerSourceHonoursEnvironmentOverride() {
    let source = GemmaEmbedder.developerSource(environment: ["EGCM_MODEL_PATH": "/tmp/model"], bundle: .main)
    guard case .file(let url)? = source else { Issue.record("expected .file"); return }
    #expect(url.path == "/tmp/model")
  }

  @Test func withoutAnOverrideTheAppDownloadsThePublishedModel() {
    #expect(GemmaEmbedder.developerSource(environment: [:], bundle: Bundle(for: BundleToken.self)) == nil)
  }
  #endif
}

private final class BundleToken {}
