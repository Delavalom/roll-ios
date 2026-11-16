import Foundation
import Ranking
import Store
import Testing

/// `ROLL_BENCH=1` only: `SwipefileEngine.find` with `FindConfig.shipping` over `SearchBenchWorld` (29,681 embedded
/// rows), step by step (`FindSearch.Result.steps`). The world gets moments of 50 photos, trips of 10 moments and 3–10
/// scene labels per photo, so the event, "rest of this event" and tag steps run as on a phone. Per query: one first
/// call, then the median of 10 warm calls per step. Run in both configurations (the phone QA build is Debug, the App
/// Store build Release): `ROLL_BENCH=1 swift test --filter FindSpeedBench`, and the same with
/// `-c release -Xswiftc -enable-testing`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ROLL_BENCH"] == "1"))
struct FindSpeedBench {
  static let steps = ["understand", "embed", "words", "pool", "events", "filter", "read", "rank", "rest"]

  @Test func shippingStepByStep() async throws {
    let world = try await SearchBenchWorld.make()
    defer { world.cleanUp() }
    try await Self.addEventsAndTags(world)
    let clock = ContinuousClock()
    for query in ["a dog on the beach", "christmas 2023", "dog last summer", "zxqv blorp"] {
      _ = try await world.engine.find(query, config: .shipping)
      var totals: [Double] = []
      var steps: [String: [Double]] = [:]
      var strong = 0
      for _ in 0..<10 {
        let start = clock.now
        let result = try await world.engine.find(query, config: .shipping)
        totals.append(SearchTimings.ms(clock.now - start))
        for (step, ms) in result.steps { steps[step, default: []].append(ms) }
        strong = result.matches.count
      }
      func median(_ xs: [Double]) -> String { String(format: "%.1f", xs.sorted()[xs.count / 2]) }
      let split = Self.steps.map { "\($0)=\(median(steps[$0] ?? [0]))" }.joined(separator: " ")
      print("bench find shipping \"\(query)\" strong=\(strong) warmMedian=\(median(totals)) \(split)")
    }
  }

  /// Moments of 50 consecutive photos, trips of 10 moments, and tags as in `SearchSpeedBench.typedSearchWithTags`.
  static func addEventsAndTags(_ world: SearchBenchWorld) async throws {
    var events: [EventRecord] = []
    var assignments: [String: String] = [:]
    for (m, start) in stride(from: 0, to: world.ids.count, by: 50).enumerated() {
      let members = world.ids[start..<min(start + 50, world.ids.count)]
      let trip = "trip-\(m / 10)"
      if m % 10 == 0 {
        events.append(EventRecord(id: trip, kind: .trip, startAt: Double(start), endAt: Double(start + 500), count: 500))
      }
      let id = "moment-\(m)"
      events.append(EventRecord(id: id, kind: .moment, startAt: Double(start), endAt: Double(start + members.count),
                                count: members.count, tripId: trip))
      for asset in members { assignments[asset] = id }
    }
    try await world.repo.replaceEvents(events, assignments: assignments)
    let vocabulary = ["sport", "ball", "grass", "beach", "sand", "ocean", "dog", "pet", "cake", "outdoor", "sky",
                      "food", "dessert", "snow", "stage", "people", "adult", "structure", "plant", "document", "text",
                      "screenshot", "night_sky", "car", "vehicle", "wedding_dress", "candle", "furniture", "child"]
    var g = SeededRNG(seed: 4)
    var items: [TagFields] = []
    for id in world.ids {
      let labels = (0..<Int.random(in: 3...10, using: &g)).map { _ in
        TagLabel(label: Int.random(in: 0..<7, using: &g) == 0 ? vocabulary.randomElement(using: &g)!
                   : "label_\(Int.random(in: 0..<600, using: &g))",
                 confidence: Double.random(in: 0.1...0.95, using: &g))
      }
      items.append(TagFields(id: id, labels: labels, revision: "bench", side: 360))
    }
    for start in stride(from: 0, to: items.count, by: 2_000) {
      try await world.repo.commitTags(Array(items[start..<min(start + 2_000, items.count)]))
    }
  }
}
