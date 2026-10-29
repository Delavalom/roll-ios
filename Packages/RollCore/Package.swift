// swift-tools-version: 6.2
import Foundation
import PackageDescription

/// The sibling checkout, or `ROLL_GEMMA_PATH` (absolute, or relative to this folder) for another checkout of the
/// package, e.g. a worktree of an unmerged branch, for `swift build` and `swift test`. It must still be a folder named
/// `swift` (the identity below). The Xcode project always uses the sibling (project.yml), so leave it unset there.
let gemmaPath = Context.environment["ROLL_GEMMA_PATH"].flatMap { $0.isEmpty ? nil : $0 }
  ?? "../../../embeddinggemma-coreml/swift"
let gemmaDir = gemmaPath.hasPrefix("/") ? gemmaPath : "\(Context.packageDirectory)/\(gemmaPath)"
let gemma = Package.Dependency.package(path: gemmaPath)
let gemmaPkg = "swift"  // path dependencies are identified by their directory name

/// The sibling checkout is required for the app and most modules. Without it (CI while that repo is private and no
/// token is set, or `ROLL_WITHOUT_GEMMA=1`), the package shrinks to the modules that don't use it, so their tests
/// still run: Library, Signals, Monitor and ModelInstall.
let hasGemma = Context.environment["ROLL_WITHOUT_GEMMA"] == nil
  && FileManager.default.fileExists(atPath: "\(gemmaDir)/Package.swift")

// Modules whose sources land in later tasks still get a target (with a `_Placeholder.swift` file)
// so the app's project.yml can reference every product from day one.
let package = Package(
  name: "RollCore",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "Embedding", targets: ["Embedding"]),
    .library(name: "ModelInstall", targets: ["ModelInstall"]),
    .library(name: "Store", targets: ["Store"]),
    .library(name: "Library", targets: ["Library"]),
    .library(name: "Signals", targets: ["Signals"]),
    .library(name: "Indexer", targets: ["Indexer"]),
    .library(name: "Ranking", targets: ["Ranking"]),
    .library(name: "Dedupe", targets: ["Dedupe"]),
    .library(name: "Squish", targets: ["Squish"]),
    .library(name: "Monitor", targets: ["Monitor"]),
    .library(name: "Entitlements", targets: ["Entitlements"]),
    .library(name: "Commit", targets: ["Commit"]),
    .library(name: "Overview", targets: ["Overview"]),
    .library(name: "SquishBridge", targets: ["SquishBridge"]),
  ],
  dependencies: [
    gemma,
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
  ],
  targets: [
    .target(name: "Embedding", dependencies: ["ModelInstall", .product(name: "EmbeddingGemma", package: gemmaPkg)]),
    // Download, verification and extraction of the published model; no dependency on the model package.
    .target(name: "ModelInstall"),
    .target(name: "Store", dependencies: [
      .product(name: "GRDB", package: "GRDB.swift"),
      .product(name: "EmbeddingIndex", package: gemmaPkg),
    ]),
    .target(name: "Library"),
    .target(name: "Signals"),
    .target(name: "Indexer", dependencies: ["Library", "Signals", "Store", "Embedding"]),
    .target(name: "Ranking", dependencies: ["Store", "Embedding"]),
    .target(name: "Dedupe", dependencies: ["Store"]),
    .target(name: "Squish", dependencies: ["Store", "Library"]),
    .target(name: "Monitor"),
    .target(name: "Entitlements", dependencies: ["Store"]),
    .target(name: "Commit", dependencies: ["Store", "Library", "Entitlements"]),
    .target(name: "Overview", dependencies: ["Store", "Ranking", "Dedupe", "Signals", "Squish", "Library"]),
    // Conforms Squish's ReplaceFlow to Commit's SquishRunner, so neither target depends on the other.
    .target(name: "SquishBridge", dependencies: ["Commit", "Squish", "Store", "Library", "Overview"]),

    .testTarget(name: "EmbeddingTests", dependencies: ["Embedding", "ModelInstall"]),
    .testTarget(name: "ModelInstallTests", dependencies: ["ModelInstall"]),
    .testTarget(name: "StoreTests", dependencies: ["Store"]),
    .testTarget(name: "EntitlementsTests", dependencies: ["Entitlements", "Store"]),
    .testTarget(name: "DedupeTests", dependencies: ["Dedupe", "Store"]),
    .testTarget(name: "MonitorTests", dependencies: ["Monitor"]),
    .testTarget(name: "SquishTests", dependencies: ["Squish", "Store", "SquishBridge", "Commit", "Entitlements", "Overview", "Library"]),
    .testTarget(name: "SignalsTests", dependencies: ["Signals"], resources: [.copy("Resources")]),
    .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    .testTarget(name: "IndexerTests", dependencies: ["Indexer", "Library", "Signals", "Store", "Embedding"]),
    .testTarget(name: "RankingTests", dependencies: ["Ranking", "Store", "Embedding"]),
    .testTarget(name: "CommitTests", dependencies: ["Commit", "Store", "Entitlements"]),
    .testTarget(name: "OverviewTests", dependencies: ["Overview", "Store", "Ranking", "Signals", "Squish"]),
  ]
)

if !hasGemma {
  let standalone: Set<String> = ["Library", "Signals", "Monitor", "ModelInstall", "LibraryTests", "SignalsTests",
                                 "MonitorTests", "ModelInstallTests"]
  package.dependencies = []
  package.targets = package.targets.filter { standalone.contains($0.name) }
  package.products = package.products.filter { standalone.contains($0.name) }
}
