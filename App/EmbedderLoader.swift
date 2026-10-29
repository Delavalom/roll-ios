import Embedding
import EmbeddingGemma
import Foundation
import ModelInstall

/// How far the on-device model download got.
struct ModelProgress: Sendable, Equatable {
  var completedBytes: Int64
  var totalBytes: Int64

  var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }

  /// "212 MB of 290 MB".
  var text: String { "\(ByteFormat.short(completedBytes)) of \(ByteFormat.short(totalBytes))" }
}

/// Why the model isn't there, for the "On-device AI" row.
enum ModelIssue: Equatable {
  /// Nothing tried yet (before Photos access).
  case notStarted
  /// `PublishedModel.current(budget:)` is still the placeholder.
  case notPublished
  case notEnoughSpace(requiredBytes: Int64)
  /// The download, the check, unpacking or loading failed; Retry starts over where it stopped.
  case failed

  init(_ error: any Error) {
    switch error {
    case ModelInstallError.notPublished: self = .notPublished
    case ModelInstallError.insufficientSpace(let required, _): self = .notEnoughSpace(requiredBytes: required)
    case EmbeddingGemmaError.insufficientStorage(let required, _): self = .notEnoughSpace(requiredBytes: required)
    default: self = .failed
    }
  }
}

/// Loads the embedder, reporting where the download and install stand.
protocol EmbedderLoader: Sendable {
  /// `allowCellular`: the person chose to download on mobile data (or in Low Data Mode); off by default.
  func load(allowCellular: Bool, report: @escaping @Sendable (InstallStep) -> Void) async throws -> any Embedder
}

/// The real EmbeddingGemma model: this device's image budget package of `PublishedModel.current(budget:)` (70 or
/// 280, from the package's device tier), downloaded in the background on Wi-Fi, verified, unpacked and installed by
/// `ModelInstaller`, loaded with `GemmaActivator` (Neural Engine and CPU) at that same budget. In DEBUG builds only, a
/// developer override (`EGCM_MODEL_PATH`, or a bundled `EmbeddingGemma` folder) replaces the download.
struct GemmaLoader: EmbedderLoader {
  let installer: ModelInstaller
  let budget: EmbeddingGemma.ImageBudget

  /// One installer per process, over the one background transport. The budget is resolved once here, so the
  /// package downloaded and the functions loaded always match.
  static func live() -> GemmaLoader {
    let tokens = GemmaEmbedder.imageTokens(for: .auto)
    return GemmaLoader(
      installer: ModelInstaller(model: .current(budget: tokens), transport: BackgroundTransport.shared,
                                conditions: InstallConditions(network: { await NetworkPathProbe.current() })),
      budget: tokens == 280 ? .tokens280 : .tokens70)
  }

  func load(allowCellular: Bool, report: @escaping @Sendable (InstallStep) -> Void) async throws -> any Embedder {
    #if DEBUG
    if let source = GemmaEmbedder.developerSource() {
      report(.activating)
      return try await GemmaEmbedder.load(source: source, budget: budget)
    }
    #endif
    return try await installer.load(allowCellular: allowCellular, activator: GemmaActivator(budget: budget),
                                    report: report)
  }
}

#if DEBUG
/// `StubEmbedder`, for previews and `-UITestStubEmbedder` launches only. Never a shipping fallback (AGENTS.md).
struct StubLoader: EmbedderLoader {
  var simulatedBytes: Int64 = 0

  func load(allowCellular: Bool, report: @escaping @Sendable (InstallStep) -> Void) async throws -> any Embedder {
    if simulatedBytes > 0 {
      for step in 1...4 {
        try await Task.sleep(for: .milliseconds(150))
        report(.downloading(completedBytes: simulatedBytes * Int64(step) / 4, totalBytes: simulatedBytes))
      }
    }
    return StubEmbedder()
  }
}
#endif
