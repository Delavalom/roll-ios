import Foundation
import Testing
@testable import Indexer
import Library
import Store

/// iCloud-only originals are analysed from their local previews (`source = preview`, `cloudOnly = 1`); the opt-in
/// upgrade pass (`upgradePreviews`, network allowed) replaces them with full images.
struct PreviewIndexingTests {
  static let previews = [FakeLibrary.id(2), FakeLibrary.id(9), FakeLibrary.id(14)]

  @Test func previewsAreAnalysedWithoutTheNetwork() async throws {
    try await Harness.with(count: 30) { h in
      h.library.set(.preview, for: Self.previews)
      let indexer = try h.indexer()
      try await indexer.sync()
      let report = try await indexer.run()
      #expect(report.previews == 3 && report.cloudOnly == 0)
      #expect(try await h.count("signalsDone = 1 AND embedded = 1") == 30)
      #expect(try await h.count("source = 'preview' AND cloudOnly = 1") == 3)
      #expect(try await h.count("source = 'full' AND cloudOnly = 0") == 27)
      #expect(h.library.state.withLock { $0.networkRequests }.isEmpty)
      #expect(try await indexer.pendingCount() == 0)
    }
  }

  @Test func theEmbedOnlyCatchUpEmbedsPreviewRowsWithoutTheNetwork() async throws {
    try await Harness.with(count: 20) { h in
      h.library.set(.preview, for: Self.previews)
      let indexer = try h.indexer(embedder: false)
      try await indexer.sync()
      try await indexer.run()
      #expect(try await h.count("source = 'preview' AND embedded = 0") == 3)
      try await indexer.setEmbedder(Harness.embedder, openVectors: h.openSameStore)
      try await indexer.run()
      #expect(try await h.count("embedded = 1") == 20)
      #expect(h.library.state.withLock { $0.networkRequests }.isEmpty)
    }
  }

  @Test func theUpgradePassReplacesPreviewsWithFullImages() async throws {
    try await Harness.with(count: 30) { h in
      h.library.set(.preview, for: Self.previews)
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      let extractedBefore = h.signals.extractCalls
      #expect(try await indexer.run(allowNetwork: true).processed == 0, "a plain network run leaves previews alone")

      let report = try await indexer.run(allowNetwork: true, upgradePreviews: true)
      #expect(report.processed == 3 && report.upgraded == 3)
      #expect(Set(h.library.state.withLock { $0.networkRequests }) == Set(Self.previews))
      #expect(h.signals.extractCalls == extractedBefore + 3, "signals recomputed from the full image")
      #expect(try await h.count("source = 'preview'") == 0)
      #expect(try await h.count("source = 'full' AND cloudOnly = 1 AND embedded = 1") == 3, "originals stay in iCloud")
      #expect(try await h.repo.previewAssetIds().isEmpty)
    }
  }

  @Test func aFailedUpgradeKeepsThePreview() async throws {
    try await Harness.with(count: 10) { h in
      h.library.set(.previewOnly, for: [FakeLibrary.id(4)])
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      let report = try await indexer.run(allowNetwork: true, upgradePreviews: true)
      #expect(report.upgraded == 0)
      #expect(try await h.repo.previewAssetIds() == [FakeLibrary.id(4)])
      #expect(try await h.count("source = 'preview' AND signalsDone = 1 AND embedded = 1") == 1)
    }
  }

  /// The upgrade pass starts again whenever Wi-Fi and charging hold; a download that keeps failing must not be retried
  /// on every pass. Each preview row gets `maxUpgradeAttempts` per launch (the Indexer lives for the launch).
  @Test func aFailedUpgradeIsRetriedOnlySoOftenPerLaunch() async throws {
    try await Harness.with(count: 10) { h in
      let stuck = FakeLibrary.id(4)
      h.library.set(.previewOnly, for: [stuck])
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      for _ in 0..<5 { try await indexer.run(allowNetwork: true, upgradePreviews: true) }
      let downloads = { h.library.state.withLock { $0.networkRequests }.filter { $0 == stuck }.count }
      #expect(downloads() == Indexer.maxUpgradeAttempts)
      #expect(try await h.repo.previewAssetIds() == [stuck], "the preview stays")
      try await h.indexer().run(allowNetwork: true, upgradePreviews: true)
      #expect(downloads() == Indexer.maxUpgradeAttempts + 1, "tried again next launch")
    }
  }
}
