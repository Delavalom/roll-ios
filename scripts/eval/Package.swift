// swift-tools-version: 6.2
import Foundation
import PackageDescription

/// The pile eval (`scripts/eval/README` is this comment): `evals/piles.json` against a copy of a real library's Store
/// and vector index, with labels from metadata. Private inputs stay outside the repo; the output has no identifiers.
///
///     ROLL_GEMMA_PATH=/abs/embeddinggemma-coreml/swift swift run pile-eval embed ...
///     ROLL_GEMMA_PATH=/abs/embeddinggemma-coreml/swift swift run pile-eval score ...
///     swift test   (PileEvalKit: the metrics, no model or data needed)
///
/// It reuses RollCore (`Preset` prompts, `GemmaEmbedder`) and EmbeddingIndex (`VectorIndex.dotAll`), so the prompts,
/// the query embedding and the dot products are the app's own. `ROLL_GEMMA_PATH` works as in RollCore.
let gemmaPath = Context.environment["ROLL_GEMMA_PATH"].flatMap { $0.isEmpty ? nil : $0 }
  ?? "../../../embeddinggemma-coreml/swift"

let package = Package(
  name: "PileEval",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(path: "../../Packages/RollCore"),
    .package(path: gemmaPath),
  ],
  targets: [
    .target(name: "PileEvalKit"),
    .executableTarget(name: "pile-eval", dependencies: [
      "PileEvalKit",
      .product(name: "Embedding", package: "RollCore"),
      .product(name: "Ranking", package: "RollCore"),
      .product(name: "EmbeddingIndex", package: "swift"),
      .product(name: "EmbeddingGemma", package: "swift"),
    ], linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "PileEvalKitTests", dependencies: ["PileEvalKit"]),
  ]
)
