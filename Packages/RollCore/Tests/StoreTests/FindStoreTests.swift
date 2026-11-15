import Foundation
import GRDB
import Testing
@testable import Store

/// Schema v11 reads and writes: location, events, saved searches, rowids. Synthetic data only.
struct FindStoreTests {
  @Test func upsertWritesLocationAndKeepsTheEventId() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([AssetRecord(id: "a", mediaType: 1, subtypes: 0, created: 10, lat: 1.5, lon: 2.5,
                                             locationChecked: true)])
    try await repo.replaceEvents([EventRecord(id: "m:a", kind: .moment, startAt: 10, endAt: 10, count: 1)],
                                 assignments: ["a": "m:a"])
    // The library drops the location (edited away): the row follows, the moment stays until the next pass.
    try await repo.upsertAssets([AssetRecord(id: "a", mediaType: 1, subtypes: 0, created: 10, locationChecked: true)])
    let a = try #require(try await repo.asset(id: "a"))
    #expect(a.lat == nil && a.lon == nil && a.locationChecked && a.eventId == "m:a")
  }

  @Test func eventInputRowsAreLiveDatedRowsOldestFirst() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([
      AssetRecord(id: "b", mediaType: 1, subtypes: 0, created: 20, lat: 3, lon: 4, locationChecked: true),
      AssetRecord(id: "a", mediaType: 1, subtypes: 0, created: 10),
      AssetRecord(id: "undated", mediaType: 1, subtypes: 0),
      AssetRecord(id: "gone", mediaType: 1, subtypes: 0, created: 5),
    ])
    try await repo.markDeleted(["gone"])
    let rows = try await repo.eventInputRows()
    #expect(rows == [EventInputRow(id: "a", created: 10, lat: nil, lon: nil),
                     EventInputRow(id: "b", created: 20, lat: 3, lon: 4)])
  }

  @Test func replaceEventsWritesOnlyChangedRows() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets((0..<4).map { AssetRecord(id: "a\($0)", mediaType: 1, subtypes: 0, created: Double($0)) })
    let trip = EventRecord(id: "t:a0", kind: .trip, startAt: 0, endAt: 3, count: 4, countryCode: "PR")
    let m1 = EventRecord(id: "m:a0", kind: .moment, startAt: 0, endAt: 1, count: 2, tripId: "t:a0")
    let m2 = EventRecord(id: "m:a2", kind: .moment, startAt: 2, endAt: 3, count: 2, tripId: "t:a0")
    let assign = ["a0": "m:a0", "a1": "m:a0", "a2": "m:a2", "a3": "m:a2"]
    #expect(try await repo.replaceEvents([trip, m1, m2], assignments: assign) == 4)
    #expect(try await repo.events().map(\.id) == ["m:a0", "t:a0", "m:a2"])

    let changes = try await repo.observeRankingChanges()
    let before = changes.generation
    #expect(try await repo.replaceEvents([trip, m1, m2], assignments: assign) == 0)
    #expect(changes.generation == before)  // same events: the ranking pool stays current
    #expect(try await repo.replaceEvents([m1], assignments: ["a0": "m:a0", "a1": "m:a0"]) == 2)
    #expect(changes.generation > before)
    #expect(try await repo.asset(id: "a3")?.eventId == nil)
    #expect(try await repo.events() == [m1])
    let rows = try await repo.rankingRows()
    #expect(rows.first { $0.asset.id == "a1" }?.eventId == "m:a0")
    #expect(rows.first { $0.asset.id == "a1" }?.created == 1)
  }

  @Test func savedSearchesRoundTripAndTheirWatermarkOnlyMovesForward() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.save(SwipefileRecord(id: "sf", name: "Soccer", kind: .custom, prompts: ["soccer"], examples: [],
                                        action: .album, albumName: "Soccer", created: 0))
    let saved = SavedSearchRecord(id: "s1", query: "soccer", albumName: "Soccer", swipefileId: "sf", createdAt: 5,
                                  lastSeenRowid: 3)
    try await repo.save(saved)
    #expect(try await repo.savedSearch(id: "s1") == saved)
    try await repo.markSavedSearchRun(id: "s1", lastSeenRowid: 10, at: 7)
    try await repo.markSavedSearchRun(id: "s1", lastSeenRowid: 4, at: 8)
    let run = try #require(try await repo.savedSearch(id: "s1"))
    #expect(run.lastSeenRowid == 10 && run.lastRunAt == 8)
    try await repo.deleteSwipefile(id: "sf")
    #expect(try await repo.savedSearch(id: "s1")?.swipefileId == nil)  // the album survives its pile
    try await repo.save(SavedSearchRecord(id: "s0", query: "beach", albumName: "Beach", createdAt: 1))
    #expect(try await repo.savedSearches().map(\.id) == ["s0", "s1"])
    try await repo.deleteSavedSearch(id: "s1")
    #expect(try await repo.savedSearches().map(\.id) == ["s0"])
  }

  @Test func rowidsGrowWithNewRowsAndTrackUnembeddedOnes() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    #expect(try await repo.maxAssetRowid() == 0)
    try await repo.upsertAssets([AssetRecord(id: "a", mediaType: 1, subtypes: 0),
                                 AssetRecord(id: "b", mediaType: 1, subtypes: 0)])
    let first = try await repo.maxAssetRowid()
    try await repo.upsertAssets([AssetRecord(id: "a", mediaType: 1, subtypes: 0),
                                 AssetRecord(id: "c", mediaType: 1, subtypes: 0)])
    let rowids = try await repo.assetRowids(ids: ["a", "b", "c", "missing"])
    #expect(rowids.count == 3)
    #expect(rowids["c"]! > first && rowids["a"]! < rowids["b"]!)  // an upsert keeps the row's rowid
    try await repo.markEmbedded(ids: ["a", "c"])
    #expect(try await repo.firstUnembeddedRowid(after: 0) == rowids["b"])
    #expect(try await repo.firstUnembeddedRowid(after: rowids["b"]!) == nil)
  }
}
