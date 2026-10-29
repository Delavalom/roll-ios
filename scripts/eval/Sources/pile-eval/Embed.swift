import Embedding
import EmbeddingGemma
import Foundation
import PileEvalKit
import Ranking

/// Query vectors, keyed by query text, with the revision they must match.
struct QueryVectors: Codable {
  var revision: String
  var dimensions: Int
  var vectors: [String: [Float]]
}

extension PileQuery {
  /// What gets embedded: the typed text, or the pile's prompts (`Preset.prompts`, the app's own).
  func prompts() throws -> [String] {
    if let text { return [text] }
    guard let raw = preset, let preset = Preset(rawValue: raw) else {
      throw PileSpec.Invalid(description: "\(name): unknown preset \(self.preset ?? "")")
    }
    guard !preset.prompts.isEmpty else { throw PileSpec.Invalid(description: "\(name): \(raw) has no prompts") }
    return preset.prompts
  }
}

/// Embeds every prompt of `spec` with the model at `model` (the `.file` layout with `b70/`), the way the app does:
/// `GemmaEmbedder.embed(query:)` (query prefix), budget 70 so the revision matches the phone's index. Only text
/// functions load (on first use); `store` is a scratch model store, delete it afterwards.
func embedQueries(spec: PileSpec, model: URL, store: URL, out: URL) async throws {
  var texts: [String] = []
  for q in spec.queries { for p in try q.prompts() where !texts.contains(p) { texts.append(p) } }
  let started = Date()
  let embedder = try await GemmaEmbedder.load(source: .file(model), budget: .tokens70, store: ModelStore(root: store))
  print("model ready in \(Int(Date().timeIntervalSince(started))) s, revision \(embedder.revision)")
  var vectors: [String: [Float]] = [:]
  for text in texts {
    let v = try await embedder.embed(query: text)
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    vectors[text] = norm > 0 ? v.map { $0 / norm } : v  // SwipefileEngine normalizes prompt vectors too
  }
  print("embedded \(texts.count) prompts in \(Int(Date().timeIntervalSince(started))) s")
  let data = try JSONEncoder().encode(QueryVectors(revision: embedder.revision, dimensions: embedder.dimensions,
                                                   vectors: vectors))
  try data.write(to: out)
}
