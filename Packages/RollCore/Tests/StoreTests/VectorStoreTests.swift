import Foundation
import GRDB
import Testing
@testable import Store

struct VectorStoreTests {
  private func open(_ url: URL, _ db: AppDatabase, revision: String = "r1", dimensions: Int = 8) async throws -> VectorStore {
    try await VectorStore(url: url, dimensions: dimensions, revision: revision, database: db)
  }

  @Test func upsertSearchRemoveAndCount() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await open(dir.appendingPathComponent("v.egix"), try AppDatabase.inMemory())
      await store.reserve(10)
      try await store.upsert(id: "a", vector: Fixtures.unit(0))
      try await store.upsert(id: "b", vector: Fixtures.unit(1))
      #expect(await store.count == 2)

      let hits = await store.search(Fixtures.unit(1), k: 5)
      #expect(hits.map(\.id) == ["b", "a"])
      #expect(hits.first?.score == 1)

      let filtered = await store.search(Fixtures.unit(1), k: 5, filter: { $0 != "b" })
      #expect(filtered.map(\.id) == ["a"])

      #expect(await store.vector(for: "a") == Fixtures.unit(0))
      try await store.remove(id: "a")
      #expect(await store.vector(for: "a") == nil)
      #expect(await store.count == 1)
    }
  }

  @Test func batchUpsertAddsEverything() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await open(dir.appendingPathComponent("v.egix"), try AppDatabase.inMemory())
      try await store.upsert((0..<8).map { (id: "a\($0)", vector: Fixtures.unit($0)) })
      #expect(await store.count == 8)
      #expect(await store.vector(for: "a5") == Fixtures.unit(5))
      try await store.upsert([])
      #expect(await store.count == 8)
    }
  }

  @Test func batchUpsertWithABadVectorAddsNothing() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await open(dir.appendingPathComponent("v.egix"), try AppDatabase.inMemory())
      await #expect(throws: (any Error).self) {
        try await store.upsert([(id: "ok", vector: Fixtures.unit(0)), (id: "bad", vector: [1, 2, 3])])
      }
      #expect(await store.count == 0)
    }
  }

  @Test func rejectsWrongDimensions() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await open(dir.appendingPathComponent("v.egix"), try AppDatabase.inMemory())
      await #expect(throws: (any Error).self) { try await store.upsert(id: "a", vector: [1, 2, 3]) }
    }
  }

  @Test func savePersistsAcrossReopen() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("v.egix")
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      try await repo.upsertAssets([Fixtures.asset("a"), Fixtures.asset("b")])
      let store = try await open(url, db)
      try await store.upsert(id: "a", vector: Fixtures.unit(2))
      try await store.save()
      try await repo.markEmbedded(ids: ["a"])
      try await store.upsert(id: "b", vector: Fixtures.unit(3))
      try await store.save()
      try await repo.markEmbedded(ids: ["b"])

      let reopened = try await open(url, db)
      #expect(await reopened.count == 2)
      #expect(await reopened.vector(for: "a") == Fixtures.unit(2))
      #expect(!reopened.didReset)
    }
  }

  @Test func indexFolderIsExcludedFromBackupAndSurvivesSaves() async throws {
    try await Fixtures.withTempDirectory { base in
      let url = try VectorStore.defaultURL(in: base)
      let store = try await open(url, try AppDatabase.inMemory())
      try await store.upsert(id: "a", vector: Fixtures.unit(0))
      try await store.save()
      try await store.save()  // each save replaces the file; the folder flag must still cover it

      // Read through a fresh URL so no cached resource value can mask the real state.
      let folder = URL(fileURLWithPath: url.deletingLastPathComponent().path, isDirectory: true)
      #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
      #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: url.path).path))
    }
  }

  @Test func openingRemovesStaleTempFilesButKeepsOtherFiles() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("vectors.egix")
      let stale = dir.appendingPathComponent(".vectors.egix.\(UUID().uuidString).tmp")
      let other = dir.appendingPathComponent(".other.egix.\(UUID().uuidString).tmp")
      let keep = dir.appendingPathComponent("notes.txt")
      for f in [stale, other, keep] { try Data("x".utf8).write(to: f) }

      _ = try await open(url, try AppDatabase.inMemory())

      #expect(!FileManager.default.fileExists(atPath: stale.path))
      #expect(FileManager.default.fileExists(atPath: other.path))
      #expect(FileManager.default.fileExists(atPath: keep.path))
    }
  }

  // MARK: stale index

  @Test func revisionChangeDeletesTheFileAndResetsEmbeddedFlags() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("v.egix")
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      try await repo.replaceAssetsForTesting([
        Fixtures.asset("a", created: 1, embedded: true, signalsDone: true),
        Fixtures.asset("b", created: 2, embedded: true, signalsDone: true),
      ])
      var sf = Fixtures.swipefile("sf1")
      sf.classifier = SwipefileRecord.encodeClassifier([1, 2, 3]); sf.classifierRevision = "r1"
      try await repo.save(sf)
      let old = try await open(url, db, revision: "r1")
      try await old.upsert(id: "a", vector: Fixtures.unit(0))
      try await old.save()

      let store = try await open(url, db, revision: "r2")
      #expect(store.didReset)
      #expect(try await repo.swipefile(id: "sf1")?.classifier == nil)  // trained on r1 vectors
      #expect(await store.count == 0)
      #expect(store.revision == "r2")
      #expect(try await repo.asset(id: "a")?.embedded == false)
      #expect(try await repo.asset(id: "b")?.embedded == false)
      #expect(try await repo.asset(id: "a")?.signalsDone == true)  // Vision signals are kept.

      try await store.upsert(id: "a", vector: Fixtures.unit(3))
      try await store.save()
      try await repo.markEmbedded(ids: ["a"])
      let again = try await open(url, db, revision: "r2")
      #expect(!again.didReset)
      #expect(await again.count == 1)
    }
  }

  @Test func crashBetweenResetAndDeleteResetsAgainOnReopen() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("v.egix")
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      // A stale r1 file is on disk...
      let old = try await open(url, db, revision: "r1")
      try await old.upsert(id: "a", vector: Fixtures.unit(0))
      try await old.save()
      // ...and the DB side of the reset already ran (flags cleared) before the crash.
      try await repo.replaceAssetsForTesting([Fixtures.asset("a", created: 1, embedded: false, signalsDone: true)])

      let store = try await open(url, db, revision: "r2")
      #expect(store.didReset)
      #expect(await store.count == 0)
      #expect(try await repo.asset(id: "a")?.embedded == false)
    }
  }

  @Test func dimensionChangeAlsoResets() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("v.egix")
      let db = try AppDatabase.inMemory()
      let old = try await open(url, db, dimensions: 8)
      try await old.upsert(id: "a", vector: Fixtures.unit(0))
      try await old.save()
      let store = try await open(url, db, dimensions: 16)
      #expect(store.didReset)
      #expect(await store.count == 0)
    }
  }

  @Test func corruptFileResets() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("v.egix")
      try Data("not an index".utf8).write(to: url)
      let store = try await open(url, try AppDatabase.inMemory())
      #expect(store.didReset)
      #expect(await store.count == 0)
    }
  }

  // MARK: reconcile

  @Test func reconcileClearsFlagsForRowsWithoutVectors() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("v.egix")
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      let store = try await open(url, db)
      try await store.upsert(id: "has", vector: Fixtures.unit(0))
      try await repo.replaceAssetsForTesting([
        Fixtures.asset("has", created: 3, embedded: true, signalsDone: true),
        Fixtures.asset("orphan", created: 2, embedded: true, signalsDone: true),
        Fixtures.asset("never", created: 1, embedded: false, signalsDone: true),
      ])

      let cleared = try await store.reconcile()
      #expect(cleared == 1)
      #expect(try await repo.asset(id: "has")?.embedded == true)
      #expect(try await repo.asset(id: "orphan")?.embedded == false)
      #expect(try await repo.asset(id: "orphan")?.signalsDone == true)
      #expect(try await store.reconcile() == 0)
      #expect(try await repo.pendingAssets(limit: 10).map(\.id) == ["orphan", "never"])
    }
  }

  @Test func openingReconcilesFlagsWhoseVectorFileIsMissing() async throws {
    try await Fixtures.withTempDirectory { dir in
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      try await repo.replaceAssetsForTesting([Fixtures.asset("a", created: 1, embedded: true, signalsDone: true)])
      // No vector file exists (e.g. deleted by a crash after a reset, or restored without it).
      _ = try await open(dir.appendingPathComponent("v.egix"), db)
      #expect(try await repo.asset(id: "a")?.embedded == false)
    }
  }

  @Test func theDocumentedCommitOrderLeavesNoOrphansEvenIfKilledBeforeTheFlagCommit() async throws {
    try await Fixtures.withTempDirectory { dir in
      let url = dir.appendingPathComponent("v.egix")
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      try await repo.upsertAssets([Fixtures.asset("a", created: 1), Fixtures.asset("b", created: 2)])

      // upsert vectors -> save -> (killed here, flags never committed)
      let store = try await open(url, db)
      try await store.upsert([(id: "a", vector: Fixtures.unit(0)), (id: "b", vector: Fixtures.unit(1))])
      try await store.save()

      // Relaunch: no flag claims a missing vector, the unclaimed vectors are dropped, and both assets are
      // still pending (re-embedding is harmless).
      let reopened = try await open(url, db)
      #expect(await reopened.count == 0)
      #expect(try await repo.embeddedIds().isEmpty)
      #expect(try await repo.pendingAssets(limit: 10).count == 2)

      // Re-embedding in the documented order leaves nothing to repair.
      try await reopened.upsert(id: "a", vector: Fixtures.unit(0))
      try await reopened.save()
      try await repo.markEmbedded(ids: ["a"])
      #expect(try await reopened.reconcileReport() == ReconcileReport(clearedFlags: 0, removedVectors: 0))
    }
  }

  // MARK: locations

  @Test func defaultURLsLiveUnderRollInTheGivenBase() async throws {
    try await Fixtures.withTempDirectory { base in
      let vectors = try VectorStore.defaultURL(in: base)
      let sqlite = try AppDatabase.defaultURL(in: base)
      #expect(vectors == base.appendingPathComponent("Roll/Index/vectors.egix"))
      #expect(sqlite == base.appendingPathComponent("Roll/roll.sqlite"))
      #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Roll").path))
    }
  }
}

struct VectorStoreRemoveTests {
  @Test func removeIdsDropsOnlyThoseAndIgnoresUnknownIds() async throws {
    try await Fixtures.withTempDirectory { dir in
      let store = try await VectorStore(url: dir.appendingPathComponent("v.egix"), dimensions: 8, revision: "r1",
                                        database: try AppDatabase.inMemory())
      try await store.upsert((0..<4).map { (id: "a\($0)", vector: Fixtures.unit($0)) })
      try await store.remove(ids: ["a1", "a3", "missing"])
      #expect(await store.count == 2)
      #expect(await store.vector(for: "a1") == nil)
      #expect(await store.vector(for: "a0") == Fixtures.unit(0))
    }
  }
}

struct VectorStoreReconcileTests {
  /// Reverse orphans: vectors no live, flagged row claims.
  @Test func reconcileRemovesVectorsNoLiveFlaggedRowClaims() async throws {
    try await Fixtures.withTempDirectory { dir in
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      let url = dir.appendingPathComponent("v.egix")
      let store = try await VectorStore(url: url, dimensions: 8, revision: "r1", database: db)
      try await repo.replaceAssetsForTesting([
        Fixtures.asset("live", embedded: true),
        Fixtures.asset("unflagged", embedded: false),  // flag cleared, crash before the vector was removed
        Fixtures.asset("gone", embedded: true),        // deleted while no store was attached
      ])
      try await repo.markDeleted(["gone"])
      try await store.upsert([("live", Fixtures.unit(0)), ("unflagged", Fixtures.unit(1)), ("gone", Fixtures.unit(2)),
                              ("noRow", Fixtures.unit(3))])
      try await store.save()

      let report = try await store.reconcileReport()
      #expect(report == ReconcileReport(clearedFlags: 1, removedVectors: 3))
      #expect(await store.count == 1)
      #expect(await store.vector(for: "live") == Fixtures.unit(0))
      #expect(try await repo.asset(id: "gone")?.embedded == false)
      #expect(try await repo.asset(id: "live")?.embedded == true)

      // Saved: a reopened store has only the live vector, and a second pass finds nothing.
      let reopened = try await VectorStore(url: url, dimensions: 8, revision: "r1", database: db)
      #expect(await reopened.count == 1)
      #expect(try await reopened.reconcileReport() == ReconcileReport(clearedFlags: 0, removedVectors: 0))
    }
  }

  @Test func openingTheStoreRunsTheFullReconcile() async throws {
    try await Fixtures.withTempDirectory { dir in
      let db = try AppDatabase.inMemory()
      let repo = Repositories(db)
      let url = dir.appendingPathComponent("v.egix")
      do {
        let store = try await VectorStore(url: url, dimensions: 8, revision: "r1", database: db)
        try await repo.replaceAssetsForTesting([Fixtures.asset("edited", embedded: true)])
        try await store.upsert(id: "edited", vector: Fixtures.unit(0))
        try await store.save()
      }
      // A content edit cleared the flag while no store was open.
      _ = try await repo.resetForContentChange(ids: ["edited"])
      let reopened = try await VectorStore(url: url, dimensions: 8, revision: "r1", database: db)
      #expect(await reopened.vector(for: "edited") == nil)
    }
  }
}
