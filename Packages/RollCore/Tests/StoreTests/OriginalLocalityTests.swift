import Foundation
import GRDB
import Testing
@testable import Store

/// v8: locality is whether the original resource is on the device, checked directly (`setOriginalLocal`). Thumbnail
/// availability (`cloudOnly`, `source`) says nothing about it. Until checked it is unknown.
struct OriginalLocalityTests {
  @Test func localityComesOnlyFromTheOriginalCheck() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var thumbLocal = Fixtures.asset("a")
    thumbLocal.signalsDone = true; thumbLocal.source = .full; thumbLocal.cloudOnly = false
    var preview = Fixtures.asset("b")
    preview.signalsDone = true; preview.source = .preview; preview.cloudOnly = true
    try await repo.upsertAssets([thumbLocal, preview, Fixtures.asset("c")])
    #expect(try await repo.assets(ids: ["a", "b", "c"]).map(\.locality) == [.unknown, .unknown, .unknown])

    try await repo.setOriginalLocal(["a"], local: false)
    try await repo.setOriginalLocal(["b"], local: true)
    #expect(try await repo.assets(ids: ["a", "b", "c"]).map(\.locality) == [.iCloud, .onDevice, .unknown])
  }

  @Test func aSyncNeverEraseTheCheck() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Fixtures.asset("a")])
    try await repo.setOriginalLocal(["a"], local: true)
    var again = Fixtures.asset("a")
    again.estBytes = 5
    try await repo.upsertAssets([again])
    #expect(try await repo.asset(id: "a")?.locality == .onDevice)
  }

  @Test func v8ForgetsThumbnailLocalityAndSizesOldFullRows() async throws {
    let queue = try DatabaseQueue()
    try Schema.migrator.migrate(queue, upTo: "v7")
    try await queue.write { db in
      try db.execute(sql: """
        INSERT INTO asset (id, mediaType, subtypes, estBytes, signalsDone, cloudOnly, source, previewSide) VALUES
          ('full', 1, 0, 1, 1, 0, 'full', NULL), ('preview', 1, 0, 1, 1, 1, 'preview', 120), ('todo', 1, 0, 1, 0, 0, NULL, NULL)
        """)
    }
    let rows = try await Repositories(try AppDatabase(queue)).assets(ids: ["full", "preview", "todo"])
    #expect(rows.map(\.locality) == [.unknown, .unknown, .unknown])
    #expect(rows.map(\.previewSide) == [960, 120, nil], "rows analysed before v8 used 960 px thumbnails")
  }
}
