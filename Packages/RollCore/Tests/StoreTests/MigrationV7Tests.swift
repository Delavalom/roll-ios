import Foundation
import GRDB
import Testing
@testable import Store

/// v7: rows a cloud flag left stuck (not analysed, no preview) are given back to the local preview pass; the preview's
/// pixel size and per-asset video probe results get a home.
struct MigrationV7Tests {
  private func pendingLocal(_ queue: DatabaseQueue) async throws -> [String] {
    try await Repositories(try AppDatabase(queue)).pendingAssetIds(includingEmbedding: false, includingCloudOnly: false)
  }

  @Test func fromV5StuckCloudRowsReturnToTheLocalPass() async throws {
    let queue = try DatabaseQueue()
    try Schema.migrator.migrate(queue, upTo: "v5")
    try await queue.write { db in
      try db.execute(sql: """
        INSERT INTO asset (id, mediaType, subtypes, estBytes, created, signalsDone, cloudOnly) VALUES
          ('stuck', 1, 0, 1, 3, 0, 1), ('done', 1, 0, 1, 2, 1, 0), ('cloudDone', 1, 0, 1, 1, 1, 1)
        """)
    }
    #expect(try await pendingLocal(queue) == ["stuck"])
    let rows = try await Repositories(try AppDatabase(queue)).assets(ids: ["stuck", "done", "cloudDone"])
    #expect(rows.map(\.cloudOnly) == [false, false, true])
    #expect(rows.map(\.source) == [nil, .full, nil])
    #expect(rows.map(\.locality) == [.unknown, .unknown, .unknown], "locality is checked on originals (v8)")
  }

  @Test func fromV6TheSameRowsAreFreedAndPreviewRowsKept() async throws {
    let queue = try DatabaseQueue()
    try Schema.migrator.migrate(queue, upTo: "v6")
    try await queue.write { db in
      try db.execute(sql: """
        INSERT INTO asset (id, mediaType, subtypes, estBytes, created, signalsDone, cloudOnly, source) VALUES
          ('stuck', 1, 0, 1, 3, 0, 1, NULL), ('preview', 1, 0, 1, 2, 1, 1, 'preview'), ('local', 1, 0, 1, 1, 0, 0, NULL)
        """)
    }
    #expect(try await pendingLocal(queue) == ["stuck", "local"])
    let rows = try await Repositories(try AppDatabase(queue)).assets(ids: ["stuck", "preview"])
    #expect(rows.map(\.cloudOnly) == [false, true])
    #expect(rows.map(\.source) == [nil, .preview])
  }

  @Test func v7AddsThePreviewSizeAndTheProbeTable() async throws {
    let db = try AppDatabase.inMemory()
    let (asset, probe) = try await db.writer.read { db in
      (try db.columns(in: "asset").map(\.name), try db.columns(in: "videoProbe").map(\.name))
    }
    #expect(asset.contains("previewSide"))
    #expect(probe.prefix(4) == ["assetId", "verdict", "modified", "probedAt"])  // v9 adds the measured facts
  }
}
