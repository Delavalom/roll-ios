import Foundation
import Testing
@testable import Store

struct SquishJournalTests {
  private func repo() throws -> Repositories { Repositories(try AppDatabase.inMemory()) }

  @Test func beginWritesACreatingRowWithoutACopyId() async throws {
    let r = try repo()
    try await r.journalBegin(assetID: "a", originalBytes: 100, newBytes: 40, at: Date(timeIntervalSince1970: 10))
    let row = try #require(try await r.journalEntry(assetID: "a"))
    #expect(row.state == .creating && row.newAssetID == nil)
    #expect(row.originalBytes == 100 && row.newBytes == 40)
    #expect(row.createdAt == 10 && row.updatedAt == 10)
  }

  @Test func beginRefusesToOverwriteAnOpenRowButRestartsASettledOne() async throws {
    let r = try repo()
    try await r.journalBegin(assetID: "a", originalBytes: 100, newBytes: 40)
    try await r.journalNoteNewAssetAsync(assetID: "a", newAssetID: "copy")
    for state in SquishJournalRecord.State.open {
      try await r.journalSetState(assetID: "a", state: state, payload: nil)
      await #expect(throws: SquishJournalError.openEntry(assetID: "a", state: state)) {
        try await r.journalBegin(assetID: "a", originalBytes: 1, newBytes: 1)
      }
      #expect(throws: SquishJournalError.openEntry(assetID: "a", state: state)) {
        try r.journalBeginSync(assetID: "a", originalBytes: 1, newBytes: 1)
      }
      #expect(try await r.journalEntry(assetID: "a")?.newAssetID == "copy", "the open row keeps its copy")
      #expect(try await r.openJournalAssetIDs() == ["a"])
    }
    for state in [SquishJournalRecord.State.committed, .discarded] {
      try await r.journalSetState(assetID: "a", state: state, payload: nil)
      #expect(try await r.openJournalAssetIDs().isEmpty)
      try await r.journalBegin(assetID: "a", originalBytes: 7, newBytes: 3)
      let row = try #require(try await r.journalEntry(assetID: "a"))
      #expect(row.state == .creating && row.newAssetID == nil && row.originalBytes == 7)
      try await r.journalNoteNewAssetAsync(assetID: "a", newAssetID: "copy")
    }
  }

  @Test func noteNewAssetIsSynchronousAndMovesToCreated() throws {
    let r = try repo()
    try r.journalBeginSync(assetID: "a", originalBytes: 1, newBytes: 1, at: Date())
    try r.journalNoteNewAsset(assetID: "a", newAssetID: "copy-1", at: Date(timeIntervalSince1970: 20))
    let row = try #require(try r.journalEntrySync(assetID: "a"))
    #expect(row.state == .created && row.newAssetID == "copy-1" && row.updatedAt == 20)
  }

  @Test func stateAndPayloadUpdate() async throws {
    let r = try repo()
    try await r.journalBegin(assetID: "a", originalBytes: 1, newBytes: 1, at: Date())
    try await r.journalNoteNewAssetAsync(assetID: "a", newAssetID: "c")
    try await r.journalSetState(assetID: "a", state: .verified, payload: Data([1, 2, 3]))
    let row = try #require(try await r.journalEntry(assetID: "a"))
    #expect(row.state == .verified && row.payload == Data([1, 2, 3]))
    try await r.journalSetState(assetID: "a", state: .committed, payload: nil)
    #expect(try await r.journalEntry(assetID: "a")?.payload == Data([1, 2, 3]), "a nil payload keeps the stored one")
  }

  @Test func entriesFilterByState() async throws {
    let r = try repo()
    for id in ["a", "b", "c"] { try await r.journalBegin(assetID: id, originalBytes: 1, newBytes: 1, at: Date()) }
    try await r.journalSetState(assetID: "b", state: .verified, payload: nil)
    try await r.journalSetState(assetID: "c", state: .discarded, payload: nil)
    let open = try await r.journalEntries(states: [.creating, .created, .verified])
    #expect(Set(open.map(\.assetID)) == ["a", "b"])
  }

  @Test func journaledCopyIDsCoverEveryLiveCopy() async throws {
    let r = try repo()
    for (id, copy, state) in [("a", "ca", SquishJournalRecord.State.verified), ("b", "cb", .committed),
                              ("c", "cc", .discarded), ("d", nil, .creating)] as [(String, String?, SquishJournalRecord.State)] {
      try await r.journalBegin(assetID: id, originalBytes: 1, newBytes: 1, at: Date())
      if let copy { try await r.journalNoteNewAssetAsync(assetID: id, newAssetID: copy) }
      try await r.journalSetState(assetID: id, state: state, payload: nil)
    }
    #expect(try await r.journaledCopyIDs() == ["ca", "cb"], "discarded copies are gone; committed ones are still squished results")
  }

  @Test func beginReplacesAFinishedRowForTheSameAsset() async throws {
    let r = try repo()
    try await r.journalBegin(assetID: "a", originalBytes: 1, newBytes: 1, at: Date())
    try await r.journalNoteNewAssetAsync(assetID: "a", newAssetID: "c1")
    try await r.journalSetState(assetID: "a", state: .discarded, payload: nil)
    try await r.journalBegin(assetID: "a", originalBytes: 2, newBytes: 1, at: Date())
    let row = try #require(try await r.journalEntry(assetID: "a"))
    #expect(row.state == .creating && row.newAssetID == nil && row.originalBytes == 2)
  }

  @Test func pruneRemovesOnlyOldFinishedRows() async throws {
    let r = try repo()
    try await r.journalBegin(assetID: "old", originalBytes: 1, newBytes: 1, at: Date(timeIntervalSince1970: 0))
    try await r.journalSetState(assetID: "old", state: .committed, payload: nil, at: Date(timeIntervalSince1970: 0))
    try await r.journalBegin(assetID: "open", originalBytes: 1, newBytes: 1, at: Date(timeIntervalSince1970: 0))
    try await r.journalBegin(assetID: "new", originalBytes: 1, newBytes: 1, at: Date())
    try await r.journalSetState(assetID: "new", state: .committed, payload: nil)
    try await r.pruneJournal(olderThan: Date(timeIntervalSince1970: 100))
    #expect(try await r.journalEntry(assetID: "old") == nil)
    #expect(try await r.journalEntry(assetID: "open") != nil)
    #expect(try await r.journalEntry(assetID: "new") != nil)
  }
}
