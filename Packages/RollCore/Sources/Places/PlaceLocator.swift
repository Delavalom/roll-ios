import Foundation

/// Membership tests over many coordinates with a memory of nearest cities (per ~1 km cell), for a pass over a library:
/// photos cluster, so most lookups are cache hits. Not thread-safe; make one per pass.
public final class PlaceLocator {
  public let gazetteer: Gazetteer
  private var cache: [Int64: Int32] = [:]

  public init(gazetteer: Gazetteer) {
    self.gazetteer = gazetteer
  }

  /// `Gazetteer.contains`, remembering the nearest city of each ~0.01° cell.
  public func contains(_ match: PlaceMatch, latitude: Double, longitude: Double) -> Bool {
    gazetteer.contains(match, latitude, longitude) { lat, lon in nearestIndex(lat, lon) }
  }

  /// Whether the coordinate is in any of `matches`.
  public func containsAny(_ matches: [PlaceMatch], latitude: Double, longitude: Double) -> Bool {
    matches.contains { contains($0, latitude: latitude, longitude: longitude) }
  }

  /// The nearest place, remembered per cell (its `distanceKm` is from the first coordinate asked in the cell).
  public func nearest(latitude: Double, longitude: Double) -> Place? {
    guard let i = nearestIndex(latitude, longitude) else { return nil }
    return gazetteer.place(i, km: Gazetteer.distanceKm(latitude, longitude, gazetteer.latitudes[i],
                                                       gazetteer.longitudes[i]))
  }

  private func nearestIndex(_ lat: Double, _ lon: Double) -> Int? {
    guard lat.isFinite, lon.isFinite else { return nil }
    let key = Int64((lat * 100).rounded()) * 100_000 + Int64((lon * 100).rounded())
    if let hit = cache[key] { return hit >= 0 ? Int(hit) : nil }
    let found = gazetteer.nearestCity(lat, lon, maxKm: gazetteer.options.regionMaxKm)?.index
    cache[key] = Int32(found ?? -1)
    return found
  }
}
