import CoreGraphics

/// Turns images and search text into unit vectors in one shared space.
/// Implementations: `GemmaEmbedder` (real), `StubEmbedder` (tests and previews).
public protocol Embedder: Sendable {
  var dimensions: Int { get }
  /// Identifies the model; a change invalidates every stored vector.
  var revision: String { get }
  func embed(image: CGImage) async throws -> [Float]
  func embed(query: String) async throws -> [Float]
  /// Gets every part of the model ready now, one at a time, so later embeddings don't wait for it. `progress` gets
  /// (parts done, parts in all) before each part and once at the end, on an arbitrary thread.
  func prepare(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws
}

public extension Embedder {
  /// Nothing to prepare.
  func prepare(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws {}
}
