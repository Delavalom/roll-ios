import CoreGraphics
import CoreML
import EmbeddingGemma
import Foundation

/// The real embedder: a thin wrapper over the `EmbeddingGemma` actor.
public struct GemmaEmbedder: Embedder {
  public let dimensions: Int
  public let revision: String
  private let model: EmbeddingGemma

  /// `budgetTokens` is the concrete image token budget the model was loaded with (70 or 280).
  public init(model: EmbeddingGemma, dimensions: Int = 256, budgetTokens: Int) {
    self.model = model
    self.dimensions = dimensions
    self.revision = Self.makeRevision(modelRevision: model.modelRevision, budgetTokens: budgetTokens)
  }

  /// The image budget changes the vectors, so it is part of the revision: mixing budgets
  /// invalidates the stored index instead of silently comparing incompatible vectors.
  static func makeRevision(modelRevision: String, budgetTokens: Int) -> String {
    "\(modelRevision)-b\(budgetTokens)"
  }

  /// The image token budget (70 or 280) `budget` resolves to on this device, from the package (`DeviceTier`: 280 on
  /// A17 Pro and newer iPhones and on Macs, 70 otherwise). Roll resolves it once and passes the concrete budget to
  /// both the download (`PublishedModel.current(budget:)`) and `load`, so they always agree.
  public static func imageTokens(for budget: EmbeddingGemma.ImageBudget) -> Int { budget.resolved }

  /// Loads the model from `source`, installing it into the package's store first if needed (verified, compiled once,
  /// then reused). Each multifunction function (`embed_text_*`, `embed_image_<budget>_*`) is loaded on first use
  /// with its own `functionName` and `computeUnits` (the Neural Engine and the CPU by default). `progress` gets the
  /// verified bytes of that install, on an arbitrary thread.
  public static func load(
    source: EmbeddingGemma.Source,
    budget: EmbeddingGemma.ImageBudget = .auto,
    dimensions: Int = 256,
    store: ModelStore = ModelStore(),
    computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
    progress: (@Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
  ) async throws -> GemmaEmbedder {
    let tokens = imageTokens(for: budget)
    let resolved: EmbeddingGemma.ImageBudget = tokens == 70 ? .tokens70 : .tokens280
    var report: (@Sendable (InstallProgress) -> Void)?
    if let progress {
      report = { (update: InstallProgress) in progress(update.completedBytes, update.totalBytes) }
    }
    let model = try await EmbeddingGemma.load(source, budget: resolved, dimensions: dimensions, store: store,
                                              computeUnits: computeUnits, progress: report)
    return GemmaEmbedder(model: model, dimensions: dimensions, budgetTokens: tokens)
  }

  #if DEBUG
  /// A local model that replaces the published download in developer builds: `EGCM_MODEL_PATH` in the environment,
  /// else a model folder named `EmbeddingGemma` copied into the app bundle (both in the package's `.file` layout).
  /// DEBUG only: a Release build has no such override and always downloads `PublishedModel.current(budget:)`
  /// (`ModelInstaller` + `GemmaActivator`), so an environment variable or a stray bundled folder can't swap the model.
  public static func developerSource(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
  ) -> EmbeddingGemma.Source? {
    if let path = environment["EGCM_MODEL_PATH"], !path.isEmpty {
      return .file(URL(fileURLWithPath: path))
    }
    if let url = bundle.url(forResource: "EmbeddingGemma", withExtension: nil) {
      return .file(url)
    }
    return nil
  }
  #endif

  /// Loads the four text functions, then this budget's five image functions, one per `prewarm` call, so only one is
  /// compiled at a time: on a fresh install or after an app update iOS compiles each for the Neural Engine
  /// (45–230 s each on an iPhone 13 Pro Max, about 1.5 GB peak; embeddinggemma-coreml s6), and later launches load
  /// them from its cache in about 3.5 s each. Throws `EmbeddingGemmaError.insufficientStorage` when less than
  /// `EmbeddingGemma.prewarmReserve` is free: a compile could otherwise push iOS into deleting that cache. Whatever
  /// is not loaded still loads on first use.
  public func prepare(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws {
    let names = EmbeddingGemma.textFunctions + EmbeddingGemma.imageFunctions(budget: model.imageBudget)
    for (done, name) in names.enumerated() {
      progress(done, names.count)
      try await model.prewarm([name])
    }
    progress(names.count, names.count)
  }

  public func embed(image: CGImage) async throws -> [Float] {
    try await model.embed(image: image)
  }

  public func embed(query: String) async throws -> [Float] {
    try await model.embed(query: query)
  }
}
