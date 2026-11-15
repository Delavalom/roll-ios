import Foundation
import Places

/// Groups a library into events (Find V3), pure. From (id, created, lat, lon):
///
/// - **Moments**: photos in time order; a new moment starts when the pause since the previous photo exceeds
///   `Config.maxGap`, or when a located photo lies more than `Config.maxJumpKm` from the moment's last located photo.
/// - **Trips**: runs of days away from home. Home is, per calendar year, the `Config.homeCellDegrees` grid cell holding
///   the most distinct days of located photos (the whole library's when a year has under `Config.minHomeDays`). A day
///   is away when at least `Config.awayShare` of its located photos are over `Config.awayKm` from home; days without
///   located photos don't break a run (up to `Config.maxBridgeDays` of them), a day at home does. Runs of at least
///   `Config.minTripDays` days are trips; a moment belongs to the trip its first photo's day falls in.
///
/// An asset is in one moment; a moment is in at most one trip (`Event.tripId`). Ids are stable while an event's first
/// photo stays: "m:" or "t:" + that photo's id. Undated photos are in no event.
public enum EventGrouper {
  public struct Config: Sendable, Equatable, Codable {
    /// 3 h: an afternoon at the beach with a lull stays one moment; lunch and dinner don't merge.
    public var maxGap: Double = 3 * 3_600
    /// 25 km: across a city is one moment, the next town over isn't.
    public var maxJumpKm: Double = 25
    /// 50 km from home: a day trip to the next city counts as away, errands don't.
    public var awayKm: Double = 50
    public var awayShare: Double = 0.5
    /// A weekend away (2 days) is the shortest trip; a single day out is a moment.
    public var minTripDays = 2
    /// One day without located photos (indoors, a travel day) doesn't end a trip.
    public var maxBridgeDays = 1
    /// About 25 km cells for finding home.
    public var homeCellDegrees: Double = 0.25
    public var minHomeDays = 10

    public init() {}
  }

  public struct Input: Sendable, Equatable {
    public var id: String
    public var created: Double
    public var latitude: Double?
    public var longitude: Double?

    public init(id: String, created: Double, latitude: Double? = nil, longitude: Double? = nil) {
      self.id = id; self.created = created; self.latitude = latitude; self.longitude = longitude
    }
  }

  public enum Kind: String, Sendable, Codable { case moment, trip }

  public struct Event: Sendable, Equatable {
    public var id: String
    public var kind: Kind
    public var start: Double
    public var end: Double
    public var count: Int
    public var located: Int
    public var latitude: Double?
    public var longitude: Double?
    /// For a moment inside a trip.
    public var tripId: String?
    public var place: Place?
  }

  public struct Result: Sendable, Equatable {
    /// Moments and trips, by start (ties by id).
    public var events: [Event]
    /// Asset id → moment id.
    public var assignment: [String: String]
    public var moments: Int { events.filter { $0.kind == .moment }.count }
    public var trips: Int { events.filter { $0.kind == .trip }.count }
  }

  public static func group(_ inputs: [Input], config: Config = Config(), calendar: Calendar,
                           gazetteer: Gazetteer?) -> Result {
    var rows = inputs.filter { $0.created.isFinite }
    if !zip(rows, rows.dropFirst()).allSatisfy({ ($0.created, $0.id) <= ($1.created, $1.id) }) {
      rows.sort { ($0.created, $0.id) < ($1.created, $1.id) }
    }
    guard !rows.isEmpty else { return Result(events: [], assignment: [:]) }
    let locator = gazetteer.map(PlaceLocator.init)
    let tz = calendar.timeZone
    func dayIndex(_ t: Double) -> Int {
      Int(((t + Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: t)))) / 86_400).rounded(.down))
    }
    let days = rows.map { dayIndex($0.created) }

    // Moments.
    var moments: [Range<Int>] = []
    var start = 0
    var lastLocated: (Double, Double)? = nil
    for i in rows.indices {
      if i > start {
        var split = rows[i].created - rows[i - 1].created > config.maxGap
        if !split, let lat = rows[i].latitude, let lon = rows[i].longitude, let last = lastLocated {
          split = Gazetteer.distanceKm(last.0, last.1, lat, lon) > config.maxJumpKm
        }
        if split {
          moments.append(start..<i)
          start = i
          lastLocated = nil
        }
      }
      if let lat = rows[i].latitude, let lon = rows[i].longitude { lastLocated = (lat, lon) }
    }
    moments.append(start..<rows.count)

    // Trips.
    let tripDays = trips(rows, days: days, config: config, calendar: calendar)
    var tripOfDay: [Int: Int] = [:]
    for (t, range) in tripDays.enumerated() { for d in range { tripOfDay[d] = t } }

    var events: [Event] = []
    var assignment: [String: String] = [:]
    assignment.reserveCapacity(rows.count)
    var tripMoments: [Int: [Int]] = [:]  // trip → indices into `momentEvents`
    var tripMembers: [Int: [Int]] = [:]  // trip → row indices
    var momentEvents: [Event] = []
    for range in moments {
      let id = "m:" + rows[range.lowerBound].id
      if let t = tripOfDay[days[range.lowerBound]] {
        tripMoments[t, default: []].append(momentEvents.count)
        tripMembers[t, default: []].append(contentsOf: range)
      }
      for i in range { assignment[rows[i].id] = id }
      momentEvents.append(summary(rows, Array(range), id: id, kind: .moment, locator: locator))
    }
    for (t, members) in tripMembers {
      // Members come moment by moment in time order, so the first is the earliest photo.
      let id = "t:" + rows[members[0]].id
      var trip = summary(rows, members, id: id, kind: .trip, locator: nil)
      // Named after its most photographed located moment, not its centroid (which can sit in the sea between stops).
      let named = tripMoments[t, default: []].max {
        (momentEvents[$0].located, -$0) < (momentEvents[$1].located, -$1)
      }
      trip.place = named.flatMap { momentEvents[$0].place }
      for m in tripMoments[t, default: []] { momentEvents[m].tripId = id }
      events.append(trip)
    }
    events += momentEvents
    events.sort { ($0.start, $0.kind == .trip ? 0 : 1, $0.id) < ($1.start, $1.kind == .trip ? 0 : 1, $1.id) }
    return Result(events: events, assignment: assignment)
  }

  private static func summary(_ rows: [Input], _ members: [Int], id: String, kind: Kind, locator: PlaceLocator?)
    -> Event {
    var lat = 0.0, lon = 0.0, located = 0
    for i in members {
      if let a = rows[i].latitude, let o = rows[i].longitude { lat += a; lon += o; located += 1 }
    }
    let centroid: (Double, Double)? = located > 0 ? (lat / Double(located), lon / Double(located)) : nil
    let first = members.min() ?? 0, last = members.max() ?? 0
    return Event(id: id, kind: kind, start: rows[first].created, end: rows[last].created, count: members.count,
                 located: located, latitude: centroid?.0, longitude: centroid?.1, tripId: nil,
                 place: centroid.flatMap { locator?.nearest(latitude: $0.0, longitude: $0.1) })
  }

  /// Day-index ranges of trips.
  static func trips(_ rows: [Input], days: [Int], config: Config, calendar: Calendar) -> [ClosedRange<Int>] {
    struct Cell: Hashable { var r: Int; var c: Int; var year: Int }
    let size = config.homeCellDegrees
    var cellDays: [Cell: Set<Int>] = [:]
    var cellSums: [Cell: (Double, Double, Int)] = [:]
    var yearDays: [Int: Set<Int>] = [:]
    var year: [Int] = []
    year.reserveCapacity(rows.count)
    for (i, row) in rows.enumerated() {
      let y = calendar.component(.year, from: Date(timeIntervalSince1970: row.created))
      year.append(y)
      guard let lat = row.latitude, let lon = row.longitude else { continue }
      let cell = Cell(r: Int((lat / size).rounded(.down)), c: Int((lon / size).rounded(.down)), year: y)
      cellDays[cell, default: []].insert(days[i])
      let s = cellSums[cell] ?? (0, 0, 0)
      cellSums[cell] = (s.0 + lat, s.1 + lon, s.2 + 1)
      yearDays[y, default: []].insert(days[i])
    }
    guard !cellDays.isEmpty else { return [] }
    func center(_ cells: [Cell]) -> (Double, Double) {
      let s = cells.reduce((0.0, 0.0, 0)) { acc, c in
        let v = cellSums[c]!
        return (acc.0 + v.0, acc.1 + v.1, acc.2 + v.2)
      }
      return (s.0 / Double(s.2), s.1 / Double(s.2))
    }
    // The whole library's home: the location cell (all years merged) with the most distinct days.
    var merged: [String: (days: Set<Int>, cells: [Cell])] = [:]
    for (cell, d) in cellDays {
      let key = "\(cell.r),\(cell.c)"
      merged[key, default: ([], [])].days.formUnion(d)
      merged[key, default: ([], [])].cells.append(cell)
    }
    let globalBest = merged.max { ($0.value.days.count, $1.key) < ($1.value.days.count, $0.key) }!
    let globalHome = center(globalBest.value.cells)
    var homeByYear: [Int: (Double, Double)] = [:]
    for (y, d) in yearDays where d.count >= config.minHomeDays {
      let best = cellDays.filter { $0.key.year == y }
        .max { ($0.value.count, $1.key.r, $1.key.c) < ($1.value.count, $0.key.r, $0.key.c) }!
      homeByYear[y] = center([best.key])
    }

    // Day status: away (true), home (false); days without located photos are absent.
    var awayCount: [Int: (away: Int, located: Int)] = [:]
    for (i, row) in rows.enumerated() {
      guard let lat = row.latitude, let lon = row.longitude else { continue }
      let home = homeByYear[year[i]] ?? globalHome
      let far = Gazetteer.distanceKm(home.0, home.1, lat, lon) > config.awayKm
      let c = awayCount[days[i]] ?? (0, 0)
      awayCount[days[i]] = (c.away + (far ? 1 : 0), c.located + 1)
    }
    let status = awayCount.mapValues { Double($0.away) >= config.awayShare * Double($0.located) }
    var out: [ClosedRange<Int>] = []
    var current: ClosedRange<Int>? = nil
    for d in status.keys.sorted() {
      guard status[d] == true else {
        if let c = current, c.count >= config.minTripDays { out.append(c) }
        current = nil
        continue
      }
      if let c = current, d - c.upperBound <= config.maxBridgeDays + 1 {
        current = c.lowerBound...d
      } else {
        if let c = current, c.count >= config.minTripDays { out.append(c) }
        current = d...d
      }
    }
    if let c = current, c.count >= config.minTripDays { out.append(c) }
    return out
  }
}
