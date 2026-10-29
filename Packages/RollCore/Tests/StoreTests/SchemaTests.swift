import Foundation
import GRDB
import Testing
@testable import Store

struct SchemaTests {
  @Test func migrationCreatesTablesAndIndexes() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.read { db in
      let tables = try String.fetchAll(db, sql: """
        SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'grdb%' AND name NOT LIKE 'sqlite%'
          AND name NOT LIKE 'assetTextFts_%'
        """)
      #expect(Set(tables) == ["asset", "swipefile", "decision", "quota", "squishJournal", "squishRefusal", "videoProbe",
                              "assetText", "assetTextFts"])  // v10
      let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'asset_%'")
      #expect(Set(indexes) == ["asset_created", "asset_phash", "asset_pending", "asset_textGated"])
      let columns = try db.columns(in: "asset").map(\.name)
      #expect(columns == ["id", "mediaType", "subtypes", "created", "pixelW", "pixelH", "duration", "isFavorite", "burstId",
                          "uti", "estBytes", "cloudOnly", "embedded", "signalsDone", "blur", "aesthetic", "isUtility",
                          "sensitive", "phash", "featurePrint", "deleted", "deletedAt", "attempts",  // v3
                          "modified",  // v5
                          "source",  // v6
                          "previewSide",  // v7
                          "originalLocal"])  // v8
      #expect(try db.columns(in: "swipefile").map(\.name).contains("classifierRevision"))  // v2
    }
  }

  @Test func migrationIsIdempotent() throws {
    let db = try AppDatabase.inMemory()
    try Schema.migrator.migrate(db.writer)
    let applied = try db.writer.read { db in try Schema.migrator.appliedIdentifiers(db) }
    #expect(applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"])
  }

  @Test func v5KeepsEarlierRowsAndAddsSquishRefusals() async throws {
    let queue = try DatabaseQueue()
    try Schema.migrator.migrate(queue, upTo: "v4")
    try await queue.write { db in
      try db.execute(sql: "INSERT INTO asset (id, mediaType, subtypes, estBytes) VALUES ('a', 2, 0, 7)")
      try db.execute(sql: """
        INSERT INTO squishJournal (assetID, state, createdAt, updatedAt, originalBytes, newBytes)
        VALUES ('a', 'creating', 1, 1, 7, 3)
        """)
    }
    let repo = Repositories(try AppDatabase(queue))
    let a = try #require(try await repo.asset(id: "a"))
    #expect(a.estBytes == 7 && a.modified == nil)
    #expect(try await repo.journalEntry(assetID: "a")?.state == .creating)
    let refusalColumns = try await queue.read { db in try db.columns(in: "squishRefusal").map(\.name) }
    #expect(refusalColumns == ["assetId", "reason", "modified", "refusedAt"])
    // A refusal recorded before the library reported a date holds while it still reports none.
    try await repo.recordSquishRefusal(assetId: "a", reason: "why", at: Date(timeIntervalSince1970: 5))
    #expect(try await repo.activeSquishRefusals()
      == [SquishRefusalRecord(assetId: "a", reason: "why", modified: nil, refusedAt: 5)])
  }

  @Test func squishRefusalsHoldOnlyForTheModificationDateTheyRecorded() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var asset = Fixtures.asset("a")
    asset.modified = 10
    try await repo.upsertAssets([asset, Fixtures.asset("b")])
    try await repo.recordSquishRefusal(assetId: "a", reason: "first", at: Date(timeIntervalSince1970: 1))
    try await repo.recordSquishRefusal(assetId: "a", reason: "second", at: Date(timeIntervalSince1970: 2))
    try await repo.recordSquishRefusal(assetId: "b", reason: "b", at: Date(timeIntervalSince1970: 3))
    #expect(try await repo.activeSquishRefusals().map(\.reason) == ["second", "b"], "one row per asset")
    #expect(try await repo.activeSquishRefusals().first?.modified == 10)

    try await repo.markDeleted(["b"])
    #expect(try await repo.activeSquishRefusals().map(\.assetId) == ["a"], "deleted assets don't count")

    asset.modified = 11
    try await repo.upsertAssets([asset])
    #expect(try await repo.activeSquishRefusals().isEmpty, "a new modification date lifts the refusal")
  }

  @Test func v3KeepsEarlierRowsAndRebuildsThePendingIndex() throws {
    let queue = try DatabaseQueue()
    try Schema.migrator.migrate(queue, upTo: "v2")
    try queue.write { db in
      try db.execute(sql: "INSERT INTO asset (id, mediaType, subtypes, deleted) VALUES ('a', 1, 0, 0), ('b', 1, 0, 1)")
    }
    let db = try AppDatabase(queue)
    try db.writer.read { db in
      #expect(try Int.fetchOne(db, sql: "SELECT attempts FROM asset WHERE id = 'a'") == 0)
      #expect(try Double.fetchOne(db, sql: "SELECT deletedAt FROM asset WHERE id = 'a'") == nil)
      #expect(try Double.fetchOne(db, sql: "SELECT deletedAt FROM asset WHERE id = 'b'") != nil, "already-deleted rows get a date")
      let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'asset_pending'") ?? ""
      #expect(sql.contains("attempts < 3"))
    }
  }

  @Test func deletingASwipefileCascadesToItsDecisions() async throws {
    let db = try AppDatabase.inMemory()
    let repo = Repositories(db)
    try await repo.save(Fixtures.swipefile("sf1"))
    try await repo.record(DecisionRecord(swipefileId: "sf1", assetId: "a", verdict: .action, decidedAt: 1, applied: false))
    try await repo.deleteSwipefile(id: "sf1")
    #expect(try await repo.decisions(for: "sf1").isEmpty)
  }

  @Test func decisionRequiresAnExistingSwipefile() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    await #expect(throws: (any Error).self) {
      try await repo.record(DecisionRecord(swipefileId: "missing", assetId: "a", verdict: .keep, decidedAt: 1, applied: false))
    }
  }

  @Test func fileBackedDatabaseReopens() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("roll.sqlite")
      do {
        let repo = Repositories(try AppDatabase.open(at: url))
        try await repo.upsertAssets([Fixtures.asset("a")])
      }
      let repo = Repositories(try AppDatabase.open(at: url))
      #expect(try await repo.asset(id: "a")?.id == "a")
    }
  }
}
