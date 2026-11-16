import Foundation
import Places
@testable import Ranking
import Store
import Testing

private let utc: Calendar = {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "UTC")!
  return c
}()
private func t(_ m: Int, _ d: Int, _ h: Double = 12) -> Double {
  utc.date(from: DateComponents(year: 2024, month: m, day: d))!.timeIntervalSince1970 + h * 3_600
}
/// Synthetic places: "home" and "away" are arbitrary points ~310 km apart.
private let home = (10.0, 10.0)
private let away = (12.0, 12.0)

private func photo(_ id: String, _ time: Double, _ at: (Double, Double)? = nil) -> EventGrouper.Input {
  EventGrouper.Input(id: id, created: time, latitude: at?.0, longitude: at?.1)
}

/// One photo a day at home through January 2024.
private func januaryAtHome() -> [EventGrouper.Input] {
  (1...31).map { photo("h\($0)", t(1, $0), home) }
}

struct EventGrouperTests {
  @Test func momentsSplitOnLongPauses() {
    let r = EventGrouper.group([photo("a", t(3, 1, 9)), photo("b", t(3, 1, 10)), photo("c", t(3, 1, 12)),
                                photo("d", t(3, 1, 15.5))], calendar: utc, gazetteer: nil)
    #expect(r.moments == 2)
    #expect(r.assignment == ["a": "m:a", "b": "m:a", "c": "m:a", "d": "m:d"])
    let first = r.events.first { $0.id == "m:a" }!
    #expect(first.count == 3 && first.start == t(3, 1, 9) && first.end == t(3, 1, 12) && first.located == 0)
  }

  @Test func momentsSplitOnLongJumpsButNotOnPhotosWithoutLocation() {
    let r = EventGrouper.group([photo("a", t(3, 1, 9), home), photo("b", t(3, 1, 9.1)),
                                photo("c", t(3, 1, 9.2), (10.1, 10.0)),  // 11 km: same moment
                                photo("d", t(3, 1, 9.3), (10.5, 10.0))],  // 44 km from c: new moment
                               calendar: utc, gazetteer: nil)
    #expect(r.assignment == ["a": "m:a", "b": "m:a", "c": "m:a", "d": "m:d"])
    let a = r.events.first { $0.id == "m:a" }!
    #expect(a.located == 2 && abs(a.latitude! - 10.05) < 1e-9)
  }

  @Test func daysAwayFromHomeMakeATripAcrossADayWithoutLocation() {
    let trip = [photo("t1", t(2, 10, 10), away), photo("t2", t(2, 10, 18), away),
                photo("t3", t(2, 11, 12)),  // indoors all day: no location
                photo("t4", t(2, 12, 11), away)]
    let r = EventGrouper.group(januaryAtHome() + trip + [photo("back", t(2, 14), home)], calendar: utc, gazetteer: nil)
    #expect(r.trips == 1)
    let tripEvent = r.events.first { $0.kind == .trip }!
    #expect(tripEvent.id == "t:t1" && tripEvent.count == 4 && tripEvent.start == t(2, 10, 10) && tripEvent.end == t(2, 12, 11))
    for id in ["t1", "t2", "t3", "t4"] {
      let moment = r.events.first { $0.id == r.assignment[id] }!
      #expect(moment.tripId == "t:t1", "\(id)")
    }
    #expect(r.events.first { $0.id == r.assignment["back"] }!.tripId == nil)
    #expect(r.events.first { $0.id == r.assignment["h5"] }!.tripId == nil)
  }

  @Test func oneDayOutOrAHomeDayBetweenAreNoTrip() {
    let dayOut = [photo("o1", t(2, 10, 10), away), photo("o2", t(2, 10, 14), away)]
    #expect(EventGrouper.group(januaryAtHome() + dayOut, calendar: utc, gazetteer: nil).trips == 0)
    let broken = [photo("x1", t(2, 10), away), photo("x2", t(2, 11), home), photo("x3", t(2, 12), away)]
    #expect(EventGrouper.group(januaryAtHome() + broken, calendar: utc, gazetteer: nil).trips == 0)
    var config = EventGrouper.Config()
    config.minTripDays = 1
    #expect(EventGrouper.group(januaryAtHome() + dayOut, config: config, calendar: utc, gazetteer: nil).trips == 1)
  }

  @Test func idsAreStableWhenLaterPhotosArrive() {
    let base = januaryAtHome() + [photo("t1", t(2, 10), away), photo("t2", t(2, 11), away)]
    let before = EventGrouper.group(base, calendar: utc, gazetteer: nil)
    let after = EventGrouper.group(base + [photo("new", t(3, 1), home)], calendar: utc, gazetteer: nil)
    #expect(Set(before.events.map(\.id)).isSubset(of: Set(after.events.map(\.id))))
    #expect(EventGrouper.group(base.reversed(), calendar: utc, gazetteer: nil) == before)  // order doesn't matter
  }

  @Test func eventsAreNamedFromTheGazetteer() throws {
    let g = try Gazetteer.load()
    // Public city centers (GeoNames), not anyone's photos.
    let madrid = (40.4165, -3.7026)
    let lisbon = (38.7167, -9.1333)
    let trip = [photo("m1", t(2, 10), madrid), photo("m2", t(2, 10, 13), madrid), photo("l1", t(2, 11), lisbon)]
    let r = EventGrouper.group(januaryAtHome() + trip, calendar: utc, gazetteer: g)
    #expect(r.events.first { $0.id == "m:m1" }?.place?.city == "Madrid")
    #expect(r.events.first { $0.id == "m:l1" }?.place?.countryCode == "PT")
    let tripEvent = try #require(r.events.first { $0.kind == .trip })
    #expect(tripEvent.place?.city == "Madrid")  // the most photographed moment
  }

  @Test func thirtyThousandPhotosGroupQuickly() throws {
    var rows: [EventGrouper.Input] = []
    var rng = SeededRNG(seed: 11)
    var time = t(1, 1)
    for i in 0..<30_000 {
      time += Double.random(in: 60...7_200, using: &rng) * (i % 40 == 0 ? 10 : 1)
      let trip = (i / 2_000) % 5 == 4
      let center = trip ? (12.0 + Double(i / 10_000), 12.0) : home
      let located = i % 4 != 0
      rows.append(photo(String(format: "p%05d", i), time,
                        located ? (center.0 + .random(in: -0.05...0.05, using: &rng), center.1) : nil))
    }
    let g = try Gazetteer.load()
    _ = g.nearest(latitude: 0, longitude: 0)
    let start = ContinuousClock.now
    let r = EventGrouper.group(rows, calendar: utc, gazetteer: g)
    let elapsed = ContinuousClock.now - start
    print("bench events rows=30000 moments=\(r.moments) trips=\(r.trips) ms=\(SearchTimings.ms(elapsed))")
    #expect(r.assignment.count == 30_000)
    #expect(r.trips >= 1)
    #if DEBUG
    #expect(elapsed < .seconds(3), "\(elapsed)")
    #else
    #expect(elapsed < .milliseconds(200), "\(elapsed)")
    #endif
  }
}

struct EventPassTests {
  @Test func storesEventsAndRewritesOnlyWhatChanged() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var records = januaryAtHome().map {
      AssetRecord(id: $0.id, mediaType: 1, subtypes: 0, created: $0.created, lat: $0.latitude, lon: $0.longitude,
                  locationChecked: true)
    }
    records += [AssetRecord(id: "t1", mediaType: 1, subtypes: 0, created: t(2, 10), lat: away.0, lon: away.1),
                AssetRecord(id: "t2", mediaType: 1, subtypes: 0, created: t(2, 11), lat: away.0, lon: away.1),
                AssetRecord(id: "undated", mediaType: 1, subtypes: 0)]
    try await repo.upsertAssets(records)
    let pass = EventPass(repositories: repo, gazetteer: { nil }, calendar: utc)
    let first = try #require(try await pass.run())
    #expect(first.trips == 1 && first.moments == 33 && first.changedAssets == 33)
    #expect(try await repo.asset(id: "t2")?.eventId == "m:t2")
    #expect(try await repo.asset(id: "undated")?.eventId == nil)
    let stored = try await repo.events()
    #expect(stored.first { $0.id == "m:t2" }?.tripId == "t:t1")
    #expect(stored.first { $0.id == "t:t1" }?.kind == .trip)
    let second = try #require(try await pass.run())
    #expect(second.changedAssets == 0)
  }
}
