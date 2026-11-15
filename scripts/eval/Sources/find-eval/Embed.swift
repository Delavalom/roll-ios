import Embedding
import EmbeddingGemma
import FindEvalKit
import Foundation

/// Embeds every query text and its template variants (`ResolvedQuery.texts`) the way the app embeds a typed query, and
/// the way `pile-eval embed` does: `GemmaEmbedder.load(.file(model), budget: .tokens70)` so the revision matches the
/// phone's index, `embed(query:)` (query prefix), then normalized as `SwipefileEngine.search` does. Only text functions
/// load (on first use; peak about 1.6 GB on the first run while the package compiles them, then about 0.65 GB).
///
/// `out` is merged: texts already in it for the same revision are kept and not embedded again, so a private spec can
/// be added later. `store` is a scratch model store (a copy of the model and its compiled form): keep it private.
func embedCommand(specs: [URL], model: URL, store: URL, out: URL) async throws {
  let queries = try FindSpec.load(specs)
  var texts: [String] = []
  for q in queries { for t in q.texts where !texts.contains(t) { texts.append(t) } }

  let clock = ContinuousClock()
  let start = clock.now
  let embedder = try await GemmaEmbedder.load(source: .file(model), budget: .tokens70, store: ModelStore(root: store))
  print("model ready in \(clock.now - start), revision \(embedder.revision)")

  var file = QueryVectorsFile(revision: embedder.revision, dimensions: embedder.dimensions, vectors: [:])
  if FileManager.default.fileExists(atPath: out.path) {
    let old = try JSONOut.read(QueryVectorsFile.self, from: out)
    if old.revision == embedder.revision, old.dimensions == embedder.dimensions { file.vectors = old.vectors }
    else { print("existing \(out.lastPathComponent) is for another revision: replacing it") }
  }
  let todo = texts.filter { file.vectors[$0] == nil }
  let embedStart = clock.now
  for text in todo {
    let v = try await embedder.embed(query: text)
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    file.vectors[text] = norm > 0 ? v.map { $0 / norm } : v  // SwipefileEngine.normalized
  }
  print("\(queries.count) queries, \(texts.count) texts: embedded \(todo.count) in \(clock.now - embedStart) "
        + "(\(texts.count - todo.count) already there)")
  try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
  try JSONEncoder().encode(file).write(to: out, options: .atomic)
}
