import Foundation
import Testing
@testable import Indexer
import Library
import Store

/// A pass that may use the network asks offline first and downloads only the thumbnails that aren't local; a downloaded
/// one is flagged cloudOnly (source = full). None of this is locality: the Indexer never sets it (v8; the original is
/// checked separately), so it stays unknown.
struct NetworkLocalityTests {
  @Test func aNetworkPassAsksOfflineFirstAndKeepsLocalItemsLocal() async throws {
    try await Harness.with(count: 12) { h in
      let cloud = [FakeLibrary.id(3), FakeLibrary.id(8)]
      h.library.set(.inCloud, for: cloud)
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run(allowNetwork: true)  // never checked offline before
      #expect(Set(h.library.state.withLock { $0.networkRequests }) == Set(cloud), "only the iCloud ones download")
      #expect(try await h.count("cloudOnly = 1 AND source = 'full' AND signalsDone = 1") == 2)
      #expect(try await h.count("cloudOnly = 0 AND source = 'full' AND signalsDone = 1") == 10)
      let downloaded = try await h.repo.assets(ids: cloud)
      #expect(downloaded.allSatisfy { $0.locality == .unknown }, "the Indexer never decides locality")
    }
  }

  @Test func anOriginalThatBecameLocalIsSeenOfflineInTheUpgradePass() async throws {
    try await Harness.with(count: 6) { h in
      let id = FakeLibrary.id(2)
      h.library.set(.preview, for: [id])
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      #expect(try await h.repo.asset(id: id)?.cloudOnly == true)

      h.library.set(.image, for: [id])  // the user opened it in Photos; the original is local now
      let report = try await indexer.run(allowNetwork: true, upgradePreviews: true)
      #expect(report.upgraded == 1)
      #expect(h.library.state.withLock { $0.networkRequests }.isEmpty)
      let row = try #require(try await h.repo.asset(id: id))
      #expect(row.source == .full && !row.cloudOnly && row.locality == .unknown)
    }
  }

  @Test func aFailedDownloadFallsBackToTheOfflinePreview() async throws {
    try await Harness.with(count: 4) { h in
      let id = FakeLibrary.id(1)
      h.library.set(.previewOnly, for: [id])
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run(allowNetwork: true)
      let row = try #require(try await h.repo.asset(id: id))
      #expect(row.source == .preview && row.cloudOnly && row.signalsDone)
      #expect(row.previewSide == 8, "the fake preview is 8 px")
    }
  }
}
