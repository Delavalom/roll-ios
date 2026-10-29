import EmbeddingGemma
import Foundation
import ModelInstall

/// `ModelInstaller`'s activator for the real model: `EmbeddingGemma.load(.installed(folder, repo:, revision:))` moves
/// the extracted folder into the package's store as that repo and revision (a rename, nothing copied; free space for
/// the compiled model only) and compiles once. Later launches get the package's install back without touching
/// Roll's folder, which by then is empty: Roll keeps only its marker.
public struct GemmaActivator: ModelActivator {
  public let budget: EmbeddingGemma.ImageBudget
  public let dimensions: Int
  public let store: ModelStore

  public init(budget: EmbeddingGemma.ImageBudget = .auto, dimensions: Int = 256, store: ModelStore = ModelStore()) {
    self.budget = budget
    self.dimensions = dimensions
    self.store = store
  }

  public func activate(_ folder: URL, as identity: ModelIdentity) async throws -> GemmaEmbedder {
    try await GemmaEmbedder.load(source: .installed(folder, repo: identity.repo, revision: identity.revision),
                                 budget: budget, dimensions: dimensions, store: store)
  }

  public var keepAfterActivation: Set<String> { [] }

  /// Adopting found neither the package's install of that revision nor the files to install it from (the store's
  /// copy was deleted after Roll's folder was emptied, or the folder is damaged): the package says
  /// `.downloadFailed`, the only error `.installed` throws for missing files or symlinks, and only a new download
  /// helps. A compile or load failure (the package moves the files back) or a full volume keeps the folder.
  public func needsRedownload(_ error: any Error) -> Bool {
    if case .downloadFailed? = error as? EmbeddingGemmaError { true } else { false }
  }

  /// Deletes the package's installs of other revisions (never the one just loaded: the package leases it).
  public func didActivate() async {
    _ = try? await store.removeRevisions()
  }
}
