import EmbeddingIndex
import FindEvalKit
import Foundation
import Places
import Ranking
import Store

/// What the FindSearch variants read besides vectors and the store, all from the phone export (the database copy may
/// predate the location columns): dates, locations, moments and trips, Vision tags.
extension FindLibrary {
  /// The export's `created`, else nil.
  func created(_ id: String) -> Double? { export[id]?.created }
  func location(_ id: String) -> (lat: Double?, lon: Double?) { (export[id]?.lat, export[id]?.lon) }

  func gazetteer() throws -> Gazetteer? {
    if let g = gazetteerCache { return g }
    let g = try Gazetteer.load()
    gazetteerCache = .some(g)
    return g
  }

  /// Located photos for resolving places: every located asset of the export (as `embed` uses).
  func located() -> [(latitude: Double, longitude: Double)] {
    if let l = locatedCache { return l }
    let l = exportClock(Array(export.values), indexed: nil).located
    locatedCache = l
    return l
  }

  /// Moments and trips from the export with RollCore's `EventGrouper` (default config): id → moment, moment → trip.
  func events() throws -> (assignment: [String: String], tripOf: [String: String], moments: Int, trips: Int) {
    if let e = eventsCache { return e }
    let inputs = export.values.compactMap { a -> EventGrouper.Input? in
      guard let created = a.created else { return nil }
      return EventGrouper.Input(id: a.id, created: created, latitude: a.lat, longitude: a.lon)
    }
    let grouped = EventGrouper.group(inputs, calendar: .current, gazetteer: try gazetteer())
    var tripOf: [String: String] = [:]
    for e in grouped.events where e.kind == .moment { if let t = e.tripId { tripOf[e.id] = t } }
    let e = (grouped.assignment, tripOf, grouped.moments, grouped.trips)
    eventsCache = e
    return e
  }

  /// Vision identifiers with confidence >= `minConfidence` (`FindConfig.tagMinConfidence`, as the app's engine loads
  /// them from `assetTag`), folded once into a `TagIndex` per threshold. The export kept labels >= 0.1, top 10: what
  /// the app's tag pass stores.
  func tagIndex(minConfidence: Double) -> TagIndex {
    if let t = tagsCache[minConfidence] { return t }
    var labels: [String: [String]] = [:]
    for (id, line) in vision where !line.missing {
      let kept = line.labels.filter { $0.confidence >= minConfidence }.map(\.identifier)
      if !kept.isEmpty { labels[id] = kept }
    }
    let t = TagIndex(labels: labels)
    tagsCache[minConfidence] = t
    return t
  }

  /// The normalized mean of `ids`' stored vectors (`SwipefileEngine.seedCentroid`), scored against every vector.
  func seedScores(_ ids: [String]) -> [Float]? {
    var sum = [Float](repeating: 0, count: qvecs.dimensions)
    var n = 0
    for id in ids {
      guard let v = index.vector(for: id), v.count == sum.count else { continue }
      for i in v.indices { sum[i] += v[i] }
      n += 1
    }
    guard n > 0 else { return nil }
    let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
    let centroid = norm > 0 ? sum.map { $0 / norm } : sum
    return index.dotAll([centroid]).scores
  }
}
