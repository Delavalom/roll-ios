import FindEvalKit
import Foundation
import Places
import Ranking

/// What V2 makes of a query, the way `SwipefileEngine.find` does: `QueryUnderstanding.parse` with the clock at `now`,
/// `Calendar.current` and the bundled gazetteer, then `resolvingPlaces` against the library's located photos (a place
/// nobody photographed stays a word). `embed` and `pool` both call this, so the semantic text `pool` looks up is the one
/// `embed` embedded.
struct Understood {
  var understanding: QueryUnderstanding.Understanding
  var locator: PlaceLocator?

  /// The text V2 embeds; nil for a date- or place-only query (nothing to embed).
  var semanticText: String? {
    if understanding.hasFilter && understanding.isFilterOnly { return nil }
    let s = understanding.semanticText
    return s.isEmpty ? understanding.text : s
  }

  static func of(_ text: String, now: Double, gazetteer: Gazetteer?,
                 located: [(latitude: Double, longitude: Double)], config: FindConfig) -> Understood {
    var u = QueryUnderstanding.parse(text, now: Date(timeIntervalSince1970: now), calendar: .current,
                                     gazetteer: gazetteer, options: config.understandingOptions)
    var locator: PlaceLocator? = nil
    if u.hasPlaceFilter, let gazetteer {
      let place = PlaceLocator(gazetteer: gazetteer)
      u = u.resolvingPlaces(locations: located, locator: place, minimumPhotos: config.minimumPhotosPerPlace)
      locator = place
    }
    return Understood(understanding: u, locator: locator)
  }
}

/// The export's "now" (newest `created`) and located photos (those in `indexed` when given: the engine resolves places
/// against the live, embedded rows).
func exportClock(_ assets: [ExportAsset], indexed: Set<String>?) -> (now: Double?, located: [(latitude: Double, longitude: Double)]) {
  let now = assets.compactMap(\.created).max()
  let located = assets.compactMap { a -> (latitude: Double, longitude: Double)? in
    guard let lat = a.lat, let lon = a.lon, indexed.map({ $0.contains(a.id) }) ?? true else { return nil }
    return (lat, lon)
  }
  return (now, located)
}
