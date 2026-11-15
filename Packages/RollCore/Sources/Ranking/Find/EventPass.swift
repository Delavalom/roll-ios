import Foundation
import Places
import Store

/// Recomputes the library's events (`EventGrouper`) and stores them (`Repositories.replaceEvents`). The app runs it
/// after indexing drains, like the candidate checks: reading 30k rows and grouping them takes well under a second, and
/// only rows whose moment changed are written, so a pass that finds nothing new doesn't invalidate the ranking pool.
///
/// One pass at a time: a call made during a pass returns nil and makes the running pass go round once more.
public actor EventPass {
  public struct Outcome: Sendable, Equatable {
    public var moments = 0
    public var trips = 0
    /// Asset rows whose moment changed.
    public var changedAssets = 0
    public var rounds = 0
    public var elapsed: Duration = .zero

    public init() {}
  }

  private let repositories: Repositories
  private let gazetteer: @Sendable () -> Gazetteer?
  private let config: EventGrouper.Config
  private let calendar: Calendar
  private var running = false
  private var again = false

  /// `gazetteer` names events (nil: unnamed); it is asked once per round, so the bundled one loads lazily.
  public init(repositories: Repositories, gazetteer: @escaping @Sendable () -> Gazetteer? = { try? Gazetteer.load() },
              config: EventGrouper.Config = EventGrouper.Config(), calendar: Calendar = .current) {
    self.repositories = repositories
    self.gazetteer = gazetteer
    self.config = config
    self.calendar = calendar
  }

  /// Groups and stores. Nil when folded into a running pass.
  public func run() async throws -> Outcome? {
    guard !running else {
      again = true
      return nil
    }
    running = true
    defer { running = false }
    var outcome = Outcome()
    let start = ContinuousClock.now
    repeat {
      again = false
      let rows = try await repositories.eventInputRows()
      let inputs = rows.map { EventGrouper.Input(id: $0.id, created: $0.created, latitude: $0.lat, longitude: $0.lon) }
      let result = EventGrouper.group(inputs, config: config, calendar: calendar, gazetteer: gazetteer())
      outcome.changedAssets += try await repositories.replaceEvents(result.events.map(EventRecord.init),
                                                                    assignments: result.assignment)
      outcome.moments = result.moments
      outcome.trips = result.trips
      outcome.rounds += 1
    } while again
    outcome.elapsed = ContinuousClock.now - start
    return outcome
  }
}

extension EventRecord {
  init(_ event: EventGrouper.Event) {
    self.init(id: event.id, kind: event.kind == .trip ? .trip : .moment, startAt: event.start, endAt: event.end,
              count: event.count, located: event.located, lat: event.latitude, lon: event.longitude,
              tripId: event.tripId, city: event.place?.city, admin1: event.place?.admin1, country: event.place?.country,
              countryCode: event.place?.countryCode)
  }
}
