#if DEBUG
import Foundation
import GRDB
import Testing
@testable import Store

/// `-UITestResetState` must never lose an unfinished squish (review 2026-10-24, finding 1).
struct UITestResetTests {
  /// `<base>/Roll/roll.sqlite` with one asset, a swipefile, a used quota, a refusal and the given journal rows, plus a
  /// stand-in vector index next to it.
  private func seed(_ base: URL, journal: [(String, String?, SquishJournalRecord.State)]) async throws -> URL {
    let url = try AppDatabase.defaultURL(in: base)
    let database = try AppDatabase.open(at: url)
    let r = Repositories(database)
    try await r.replaceAssetsForTesting([Fixtures.asset("a"), Fixtures.asset("b")])
    try await r.save(Fixtures.swipefile())
    _ = try await r.consumeCounter(key: "free", n: 3, limit: 10)
    try await r.recordSquishRefusal(assetId: "b", reason: "dolby")
    try await r.commitText([TextFields(id: "a", text: "words in an image", revision: "r", side: 960)])
    for (id, copy, state) in journal {
      try await r.journalBegin(assetID: id, originalBytes: 100, newBytes: 40)
      if let copy { try await r.journalNoteNewAssetAsync(assetID: id, newAssetID: copy) }
      try await r.journalSetState(assetID: id, state: state, payload: Data([7]))
    }
    try database.writer.close()
    let vectors = try VectorStore.defaultURL(in: base)
    try Data([1, 2, 3]).write(to: vectors)
    return url
  }

  @Test func withoutADatabaseItRemovesTheFolder() async throws {
    try await Fixtures.withTempDirectory { base in
      let url = try AppDatabase.defaultURL(in: base)
      #expect(try AppDatabase.resetForUITests(at: url) == .removedEverything)
      #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
  }

  @Test func withOnlySettledSquishesItRemovesEverything() async throws {
    try await Fixtures.withTempDirectory { base in
      let url = try await seed(base, journal: [("a", "ca", .committed), ("b", nil, .discarded)])
      #expect(try AppDatabase.resetForUITests(at: url) == .removedEverything)
      #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "a fresh install's state")
    }
  }

  @Test func withAnOpenSquishItKeepsTheWholeJournalAndEmptiesTheRest() async throws {
    try await Fixtures.withTempDirectory { base in
      let url = try await seed(base, journal: [("a", "ca", .verified), ("b", "cb", .committed), ("c", "cc", .discarded),
                                               ("d", nil, .creating)])
      #expect(try AppDatabase.resetForUITests(at: url) == .keptSquishJournal(openSquishes: 2))
      #expect(!FileManager.default.fileExists(atPath: try VectorStore.defaultURL(in: base).path), "the vector index goes")

      let database = try AppDatabase.open(at: url)
      let r = Repositories(database)
      #expect(try await r.openJournalAssetIDs() == ["a", "d"], "the recovery banner still finds them")
      #expect(try await r.journaledCopyIDs() == ["ca", "cb"], "Squish and Duplicates still skip every copy")
      #expect(try await r.journalEntry(assetID: "a")?.payload == Data([7]), "reconcile still has the verified snapshot")
      #expect(try await r.journalEntries(states: [.discarded]).map(\.assetID) == ["c"])
      let leftovers = try await database.writer.read { db in
        try ["asset", "swipefile", "decision", "quota", "squishRefusal", "videoProbe", "assetText"].map {
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
        }
      }
      #expect(leftovers == [0, 0, 0, 0, 0, 0, 0], "everything else starts over")
      // The keyword index followed its content table (its shadow tables are never emptied directly).
      try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO assetTextFts(assetTextFts) VALUES('integrity-check')")
      }
      #expect(try await r.keywordCoverage(terms: ["words"]) == [:])
      #expect(try await r.counter(key: "free") == 0)
      try database.writer.close()

      // A second reset with the squish still open keeps it again; once settled, the next reset removes everything.
      #expect(try AppDatabase.resetForUITests(at: url) == .keptSquishJournal(openSquishes: 2))
      let again = try AppDatabase.open(at: url)
      for id in ["a", "d"] { try await Repositories(again).journalSetState(assetID: id, state: .discarded, payload: nil) }
      try again.writer.close()
      #expect(try AppDatabase.resetForUITests(at: url) == .removedEverything)
    }
  }
}
#endif
