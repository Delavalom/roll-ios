// swift-tools-version: 6.2
import Foundation
import PackageDescription

/// The search evals (`scripts/eval/README` is this comment). Private inputs stay outside the repo; the output has no
/// identifiers.
///
/// - **pile-eval**: `evals/piles.json` against a copy of a real library's Store and vector index, with labels from
///   metadata (`docs/investigations/2026-10-29-pile-eval.md`).
///
///       ROLL_GEMMA_PATH=/abs/embeddinggemma-coreml/swift swift run pile-eval embed ...
///       ROLL_GEMMA_PATH=/abs/embeddinggemma-coreml/swift swift run pile-eval score ...
///
/// - **find-eval**: `evals/find.json` (+ private spec files) with pooled judging (TREC-style): `embed` the queries,
///   `pool` every variant's top k, render unlabelled pooled items as numbered `sheets`, `apply-judgments`, `score`.
///   Command lines in `Sources/find-eval/main.swift`; plan `docs/superpowers/plans/2026-11-15-find.md`.
///
///   `swift test` (PileEvalKit, FindEvalKit: metrics, pooling, sheets, labels; no model or data needed)
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
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),  // pinned with RollCore's
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
    // Pure parts of find-eval (specs, pooling, sheets, labels, metrics): Foundation + CoreGraphics/ImageIO/CoreText.
    .target(name: "FindEvalKit"),
    .executableTarget(name: "find-eval", dependencies: [
      "FindEvalKit",
      .product(name: "Embedding", package: "RollCore"),
      .product(name: "Ranking", package: "RollCore"),
      .product(name: "Store", package: "RollCore"),
      .product(name: "Places", package: "RollCore"),
      .product(name: "EmbeddingIndex", package: "swift"),
      .product(name: "EmbeddingGemma", package: "swift"),
      .product(name: "GRDB", package: "GRDB.swift"),
    ], linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "FindEvalKitTests", dependencies: ["FindEvalKit"]),
  ]
)
