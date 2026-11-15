import Foundation
import GRDB

// MARK: - Records (Schema v11)

/// A moment (photos close in time and place) or a trip (consecutive days away from home), as the event pass stored it
/// (`Ranking.EventPass`, `Repositories.replaceEvents`). A photo names its moment in `asset.eventId`; a moment inside a
/// trip names the trip in `tripId`.
public struct EventRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "event"

  public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
    case moment
    case trip
  }

  public var id: String
  public var kind: Kind
  /// First and last photo's `created` (seconds since 1970).
  public var startAt: Double
  public var endAt: Double
  /// Photos in it, and how many of them have a location.
  public var count: Int
  public var located: Int
  /// Mean of the located photos' coordinates; nil when none has one.
  public var lat: Double?
  public var lon: Double?
  /// For a moment: the trip it falls in.
  public var tripId: String?
  /// The nearest gazetteer place to the centroid (`Places.Gazetteer.nearest`).
  public var city: String?
  public var admin1: String?
  public var country: String?
  public var countryCode: String?

  public init(id: String, kind: Kind, startAt: Double, endAt: Double, count: Int, located: Int = 0, lat: Double? = nil,
              lon: Double? = nil, tripId: String? = nil, city: String? = nil, admin1: String? = nil,
              country: String? = nil, countryCode: String? = nil) {
    self.id = id; self.kind = kind; self.startAt = startAt; self.endAt = endAt; self.count = count
    self.located = located; self.lat = lat; self.lon = lon; self.tripId = tripId; self.city = city
    self.admin1 = admin1; self.country = country; self.countryCode = countryCode
  }
}

/// A living album: a typed query kept up to date. After indexing, the app asks for photos added since
/// `lastSeenRowid` that match (`SwipefileEngine.newMatches(for:)`) and offers them; nothing is added silently.
public struct SavedSearchRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "savedSearch"

  public var id: String
  public var query: String
  /// The album the matches go to.
  public var albumName: String
  /// The pile whose swipes train a classifier for this album (nil: none, or it was deleted).
  public var swipefileId: String?
  public var createdAt: Double
  public var lastRunAt: Double?
  /// `asset` rowid up to which new photos were already considered (`Repositories.maxAssetRowid` at creation).
  public var lastSeenRowid: Int64

  public init(id: String = UUID().uuidString, query: String, albumName: String, swipefileId: String? = nil,
              createdAt: Double, lastRunAt: Double? = nil, lastSeenRowid: Int64 = 0) {
    self.id = id; self.query = query; self.albumName = albumName; self.swipefileId = swipefileId
    self.createdAt = createdAt; self.lastRunAt = lastRunAt; self.lastSeenRowid = lastSeenRowid
  }
}

/// What the event pass reads per live, dated asset.
public struct EventInputRow: Sendable, Equatable {
  public var id: String
  public var created: Double
  public var lat: Double?
  public var lon: Double?
  public var eventId: String?

  public init(id: String, created: Double, lat: Double?, lon: Double?, eventId: String? = nil) {
    self.id = id; self.created = created; self.lat = lat; self.lon = lon; self.eventId = eventId
  }
}

// MARK: - Reads and writes

extension Repositories {
  /// Live rows whose location hasn't been read yet (stored before v11, not synced since).
  public func locationUncheckedCount() async throws -> Int {
    try await database.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE deleted = 0 AND locationChecked = 0") ?? 0
    }
  }

  /// Every live row with a date, oldest first (ties by id): the event pass's input.
  public func eventInputRows() async throws -> [EventInputRow] {
    try await database.writer.read { db in
      var out: [EventInputRow] = []
      let rows = try Row.fetchCursor(db, sql: """
        SELECT id, created, lat, lon, eventId FROM asset WHERE deleted = 0 AND created IS NOT NULL ORDER BY created, id
        """)
      while let row = try rows.next() {
        out.append(EventInputRow(id: row[0], created: row[1], lat: row[2], lon: row[3], eventId: row[4]))
      }
      return out
    }
  }

  /// In one transaction: replaces every event with `events` and points each asset at its moment (`assignments`: asset
  /// id → moment id; live rows not in it get no event). Only rows whose `eventId` changes are written, so a pass that
  /// finds the same events leaves the ranking pool's generation alone. Returns how many asset rows changed.
  @discardableResult
  public func replaceEvents(_ events: [EventRecord], assignments: [String: String]) async throws -> Int {
    try await database.writer.write { db in
      try db.execute(sql: "DELETE FROM event")
      for event in events { try event.insert(db) }
      var current: [String: String?] = [:]
      let rows = try Row.fetchCursor(db, sql: "SELECT id, eventId FROM asset WHERE deleted = 0")
      while let row = try rows.next() { current[row[0]] = row[1] as String? }
      let statement = try db.cachedStatement(sql: "UPDATE asset SET eventId = ? WHERE id = ?")
      var changed = 0
      for (id, old) in current {
        let new = assignments[id]
        if old != new {
          try statement.execute(arguments: [new, id])
          changed += 1
        }
      }
      return changed
    }
  }

  /// Every stored event, by start (ties by id).
  public func events() async throws -> [EventRecord] {
    try await database.writer.read { db in
      try EventRecord.order(Column("startAt"), Column("id")).fetchAll(db)
    }
  }

  // MARK: Saved searches

  public func save(_ saved: SavedSearchRecord) async throws {
    try await database.writer.write { db in try saved.save(db) }
  }

  public func savedSearch(id: String) async throws -> SavedSearchRecord? {
    try await database.writer.read { db in try SavedSearchRecord.fetchOne(db, key: id) }
  }

  /// Every saved search, oldest first.
  public func savedSearches() async throws -> [SavedSearchRecord] {
    try await database.writer.read { db in
      try SavedSearchRecord.order(Column("createdAt"), Column("id")).fetchAll(db)
    }
  }

  public func deleteSavedSearch(id: String) async throws {
    _ = try await database.writer.write { db in try SavedSearchRecord.deleteOne(db, key: id) }
  }

  /// Records a run: new photos up to `lastSeenRowid` were considered at `at`. The watermark never goes back.
  public func markSavedSearchRun(id: String, lastSeenRowid: Int64, at: Double) async throws {
    try await database.writer.write { db in
      try db.execute(sql: """
        UPDATE savedSearch SET lastRunAt = ?, lastSeenRowid = MAX(lastSeenRowid, ?) WHERE id = ?
        """, arguments: [at, lastSeenRowid, id])
    }
  }

  // MARK: Rowids (the order rows reached the Store)

  /// The largest `asset` rowid (0 for an empty table). A new library item gets a larger one than every stored row:
  /// rows are never removed (gone items are marked deleted), and an upsert keeps a row's rowid.
  public func maxAssetRowid() async throws -> Int64 {
    try await database.writer.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM asset") ?? 0 }
  }

  /// The smallest rowid after `after` of a live row not embedded yet: a saved search must not move past it, or that
  /// photo would never be offered once it is embedded.
  public func firstUnembeddedRowid(after: Int64) async throws -> Int64? {
    try await database.writer.read { db in
      try Int64.fetchOne(db, sql: "SELECT MIN(rowid) FROM asset WHERE rowid > ? AND deleted = 0 AND embedded = 0",
                         arguments: [after])
    }
  }

  /// Rowids of those of `ids` that exist.
  public func assetRowids(ids: [String]) async throws -> [String: Int64] {
    guard !ids.isEmpty else { return [:] }
    return try await database.writer.read { db in
      var out: [String: Int64] = [:]
      for start in stride(from: 0, to: ids.count, by: 500) {
        let batch = Array(ids[start..<min(start + 500, ids.count)])
        let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
        let rows = try Row.fetchCursor(db, sql: "SELECT id, rowid FROM asset WHERE id IN (\(marks))",
                                       arguments: StatementArguments(batch))
        while let row = try rows.next() { out[row[0]] = row[1] }
      }
      return out
    }
  }
}
