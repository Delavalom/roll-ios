import Foundation
import Testing
@testable import Indexer
import Library
import Store

/// The Indexer analyses 300 px images: the size the library answers locally for every asset (device probe), enough for
/// the 256 px blur analysis, and recorded per row (`previewSide`) so small previews can be left out of grouping.
struct AnalysisSizeTests {
  @Test func theIndexerAsksFor300PixelImages() async throws {
    #expect(IndexerConfig().thumbnailSide == 300)
    var config = Harness.testConfig
    config.thumbnailSide = IndexerConfig().thumbnailSide
    try await Harness.with(count: 12) { h in
      let indexer = try h.indexer(config: config)
      try await indexer.sync()
      try await indexer.run()
      #expect(Set(h.library.state.withLock { $0.requestedSides }) == [300])
    }
  }

  @Test func theRequestedSizeGroupsWithMarginToSpare() {
    let side = IndexerConfig().thumbnailSide
    #expect(AssetRecord.minimumGroupingSide <= side - 10, "a resize a few pixels short of the request still groups")
    #expect(AssetRecord.minimumGroupingSide > 256, "the small local previews (median 120 px) never do")
  }

  @Test func everyAnalysedRowRecordsItsImageSize() async throws {
    try await Harness.with(count: 6) { h in
      h.library.set(.preview, for: [FakeLibrary.id(1)])
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      #expect(try await h.count("signalsDone = 1 AND previewSide = 8") == 6, "fake images are 8 px, full or preview")
    }
  }
}
