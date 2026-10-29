import Foundation
import GRDB
import Testing
@testable import Store

/// v6: where an asset's signals came from (`source`: the local preview of an iCloud-only original, or the full
/// image) and what that says about where the original is (`locality`).
struct AnalysisSourceTests {
  let repo: Repositories
  let db: AppDatabase

  init() throws {
    db = try AppDatabase.inMemory()
    repo = Repositories(db)
  }

  @Test func commitSignalsRecordsTheSource() async throws {
    try await repo.upsertAssets([Fixtures.asset("p"), Fixtures.asset("f"), Fixtures.asset("c")])
    try await repo.commitSignals([
      SignalFields(id: "p", signalsDone: true, blur: 3, cloudOnly: true, source: .preview),
      SignalFields(id: "f", signalsDone: true, blur: 4, cloudOnly: false, source: .full),
      SignalFields(id: "c", signalsDone: false, cloudOnly: true, source: nil),
    ])
    let rows = try await repo.assets(ids: ["p", "f", "c"])
    #expect(rows.map(\.source) == [.preview, .full, nil])
    #expect(rows.map(\.locality) == [.unknown, .unknown, .unknown], "thumbnails never decide locality (v8)")
    #expect(Fixtures.asset("new").locality == .unknown, "not looked at yet")
  }

  @Test func aLocalPassStillEmbedsPreviewRowsButSkipsCloudRowsWithoutOne() async throws {
    try await repo.upsertAssets([Fixtures.asset("preview", created: 3), Fixtures.asset("cloud", created: 2),
                                 Fixtures.asset("local", created: 1)])
    try await repo.commitSignals([
      SignalFields(id: "preview", signalsDone: true, cloudOnly: true, source: .preview),
      SignalFields(id: "cloud", signalsDone: false, cloudOnly: true, source: nil),
    ])
    #expect(try await repo.pendingAssetIds(includingEmbedding: true, includingCloudOnly: false) == ["preview", "local"])
    #expect(try await repo.pendingAssetIds(includingEmbedding: false, includingCloudOnly: false) == ["local"])
    #expect(try await repo.pendingAssetCount(includingEmbedding: true, includingCloudOnly: false) == 2)
  }

  @Test func previewRowsAreListedForTheICloudUpgrade() async throws {
    try await repo.upsertAssets([Fixtures.asset("old", created: 1), Fixtures.asset("new", created: 9),
                                 Fixtures.asset("full", created: 5), Fixtures.asset("gone", created: 7)])
    try await repo.commitSignals(["old", "new", "gone"].map { SignalFields(id: $0, signalsDone: true, cloudOnly: true, source: .preview) }
      + [SignalFields(id: "full", signalsDone: true, cloudOnly: false, source: .full)])
    try await repo.markDeleted(["gone"])
    #expect(try await repo.previewAssetIds() == ["new", "old"])
    #expect(try await repo.previewAssetCount() == 2)
  }

  @Test func v6MarksRowsAnalysedBeforeItAsFull() async throws {
    let queue = try DatabaseQueue()
    try Schema.migrator.migrate(queue, upTo: "v5")
    try await queue.write { db in
      try db.execute(sql: """
        INSERT INTO asset (id, mediaType, subtypes, estBytes, signalsDone, cloudOnly) VALUES
          ('done', 1, 0, 1, 1, 0), ('cloud', 1, 0, 1, 0, 1), ('todo', 1, 0, 1, 0, 0)
        """)
    }
    let repo = Repositories(try AppDatabase(queue))
    let rows = try await repo.assets(ids: ["done", "cloud", "todo"])
    #expect(rows.map(\.source) == [.full, nil, nil])
    // Locality comes only from the original-resource check (v8), so nothing is known yet.
    #expect(rows.map(\.locality) == [.unknown, .unknown, .unknown])
  }
}
