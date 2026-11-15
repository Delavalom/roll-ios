import Foundation

/// Nearest city, name matching and membership.
extension Gazetteer {
  // MARK: - Nearest

  static func cell(_ lat: Double, _ lon: Double) -> Int {
    let r = min(max(Int((lat + 90).rounded(.down)), 0), 179)
    let c = ((Int((lon + 180).rounded(.down)) % 360) + 360) % 360
    return r * 360 + c
  }

  /// Great-circle distance in kilometres.
  public static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let toRad = Double.pi / 180
    let dLat = (lat2 - lat1) * toRad, dLon = (lon2 - lon1) * toRad
    let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * toRad) * cos(lat2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * 6_371.0 * asin(min(1, a.squareRoot()))
  }

  /// Index and distance of the city nearest the coordinate, if one lies within `maxKm`.
  func nearestCity(_ lat: Double, _ lon: Double, maxKm: Double) -> (index: Int, km: Double)? {
    guard lat.isFinite, lon.isFinite, abs(lat) <= 90 else { return nil }
    let row = min(max(Int((lat + 90).rounded(.down)), 0), 179)
    let col = ((Int((lon + 180).rounded(.down)) % 360) + 360) % 360
    var best: (index: Int, km: Double)? = nil
    func visit(_ r: Int, _ c: Int) {
      for i32 in grid[r * 360 + ((c % 360) + 360) % 360] {
        let i = Int(i32)
        let km = Self.distanceKm(lat, lon, latitudes[i], longitudes[i])
        if km <= maxKm, best.map({ km < $0.km }) ?? true { best = (i, km) }
      }
    }
    for ring in 0...180 {
      // Cells of ring `ring` are at least `ring - 1` degrees away in latitude or in longitude; a degree of longitude is
      // shortest at the highest latitude the ring reaches.
      if ring > 1 {
        let farthestLat = min(abs(lat) + Double(ring), 89.9)
        let floorKm = Double(ring - 1) * 111.2 * max(cos(farthestLat * .pi / 180), 0.000_1)
        if floorKm > min(best?.km ?? maxKm, maxKm) { break }
      }
      let wraps = 2 * ring + 1 >= 360
      for r in (row - ring)...(row + ring) where r >= 0 && r < 180 {
        // A row whose nearest edge is already farther than the limit can't hold anything closer.
        if Double(max(abs(r - row) - 1, 0)) * 111.2 > min(best?.km ?? maxKm, maxKm) { continue }
        if r == row - ring || r == row + ring {
          for c in wraps ? Array(0..<360) : Array((col - ring)...(col + ring)) { visit(r, c) }
        } else if !wraps {
          visit(r, col - ring)
          if ring > 0 { visit(r, col + ring) }
        }
      }
      if wraps { break }
    }
    return best
  }

  /// The nearest city within `maxKm` (default `Options.nearestMaxKm`), with its division and country.
  public func nearest(latitude: Double, longitude: Double, maxKm: Double? = nil) -> Place? {
    nearestCity(latitude, longitude, maxKm: maxKm ?? options.nearestMaxKm).map { place($0.index, km: $0.km) }
  }

  func place(_ i: Int, km: Double) -> Place {
    let c = Int(cityCountry[i]), a = Int(cityAdmin1[i])
    return Place(city: cityNames[i], admin1: a >= 0 ? admin1Names[a] : nil, admin1Code: a >= 0 ? admin1Codes[a] : nil,
                 country: c >= 0 ? countryNames[c] : "", countryCode: c >= 0 ? countryCodes[c] : "",
                 latitude: latitudes[i], longitude: longitudes[i], population: Int(populations[i]), distanceKm: km)
  }

  // MARK: - Names

  /// `Options.cityBaseRadiusKm + cityRadiusPerDecadeKm · log10(population / 15,000)`, never under the base.
  public func cityRadiusKm(population: Int) -> Double {
    options.cityBaseRadiusKm + options.cityRadiusPerDecadeKm * max(0, log10(Double(max(population, 1)) / 15_000))
  }

  /// Places named by runs of `terms` (query words, folded here with `fold`), longest run first, left to right; runs
  /// don't overlap. A run can name several places (a country and a state called Georgia, six cities called San Juan):
  /// each is returned with the same `terms`. One-word runs need at least 3 letters and must not be in
  /// `Options.commonWords`; runs made only of digits never match. An all-uppercase 2-letter term that is a country
  /// code ("PR", "US") names that country when the caller passes it unfolded.
  public func match(_ terms: [String]) -> [PlaceMatch] {
    let folded = terms.map(Self.fold)
    var out: [PlaceMatch] = []
    var i = 0
    while i < folded.count {
      var advanced = false
      for length in stride(from: min(options.maxWords, folded.count - i), through: 1, by: -1) {
        let range = i..<(i + length)
        let found = matches(for: Array(folded[range]), original: length == 1 ? terms[i] : nil, range: range)
        if !found.isEmpty {
          out += found
          i += length
          advanced = true
          break
        }
      }
      if !advanced { i += 1 }
    }
    return out
  }

  private func matches(for words: [String], original: String?, range: Range<Int>) -> [PlaceMatch] {
    if words.count == 1, let original, original.count == 2, original == original.uppercased(),
       original.allSatisfy(\.isLetter), let c = countryIndex[original] {
      return [countryMatch(Int(c), range)]
    }
    let key = words.joined(separator: " ")
    guard !key.isEmpty, !key.allSatisfy({ $0.isNumber || $0 == " " }) else { return [] }
    if words.count == 1, key.count < 3 || options.commonWords.contains(key) { return [] }
    guard let entries = names[key] else { return [] }
    var out: [PlaceMatch] = []
    var cities: [Int] = []
    for entry in entries {
      switch entry {
      case .country(let c): out.append(countryMatch(Int(c), range))
      case .admin1(let a):
        let code = admin1Codes[Int(a)]
        out.append(PlaceMatch(kind: .admin1, name: admin1Names[Int(a)], terms: range,
                              countryCode: String(code.prefix { $0 != "." }), admin1Code: code))
      case .city(let c): cities.append(Int(c))
      }
    }
    cities.sort { populations[$0] != populations[$1] ? populations[$0] > populations[$1] : $0 < $1 }
    for i in cities.prefix(options.maxCitiesPerName) {
      let c = Int(cityCountry[i]), a = Int(cityAdmin1[i])
      out.append(PlaceMatch(kind: .city, name: cityNames[i], terms: range, countryCode: c >= 0 ? countryCodes[c] : "",
                            admin1Code: a >= 0 ? admin1Codes[a] : nil, latitude: latitudes[i], longitude: longitudes[i],
                            population: Int(populations[i]), radiusKm: cityRadiusKm(population: Int(populations[i]))))
    }
    return out
  }

  private func countryMatch(_ c: Int, _ range: Range<Int>) -> PlaceMatch {
    PlaceMatch(kind: .country, name: countryNames[c], terms: range, countryCode: countryCodes[c])
  }

  // MARK: - Membership

  /// Whether the coordinate is in `match` (see the type's notes). Repeated lookups should go through a `PlaceLocator`,
  /// which remembers nearest cities.
  public func contains(_ match: PlaceMatch, latitude: Double, longitude: Double) -> Bool {
    contains(match, latitude, longitude) { nearestCity($0, $1, maxKm: options.regionMaxKm)?.index }
  }

  func contains(_ match: PlaceMatch, _ lat: Double, _ lon: Double, nearest: (Double, Double) -> Int?) -> Bool {
    switch match.kind {
    case .city:
      guard let clat = match.latitude, let clon = match.longitude else { return false }
      return Self.distanceKm(lat, lon, clat, clon) <= (match.radiusKm ?? cityRadiusKm(population: match.population))
    case .admin1:
      guard let code = match.admin1Code, let a = admin1Index[code], let i = nearest(lat, lon) else { return false }
      return cityAdmin1[i] == a
    case .country:
      guard let c = countryIndex[match.countryCode] else { return false }
      if let box = countryBoxes[Int(c)],
         lat < box.0 || lat > box.1 || (box.2 >= -180 && box.3 <= 180 && (lon < box.2 || lon > box.3)) {
        return false
      }
      guard let i = nearest(lat, lon) else { return false }
      return cityCountry[i] == c
    }
  }

  /// One-word place names that are everyday photo-query words (see `Options.commonWords`). Folded.
  public static let defaultCommonWords: Set<String> = [
    "airport", "alliance", "along", "anthem", "antelope", "apex", "archway", "aurora", "badger", "bake", "bank", "bar",
    "barking", "bath", "bay", "bear", "bell", "bend", "best", "boom", "boulder", "bow", "brick", "bride", "buffalo",
    "bush", "butterfly", "can", "canton", "capital", "cascade", "cat", "center", "central", "centre", "chandler",
    "cine", "city", "clay", "coast", "cocoa", "coin", "come", "commonwealth", "concord", "corona", "cove", "crystal",
    "cypress", "date", "deal", "defiance", "delta", "derby", "dig", "dome", "drama", "eagle", "east", "eastern",
    "enterprise", "eureka", "evergreen", "falcon", "fate", "federal", "fleet", "flint", "flora", "forest",
    "fountain", "gap", "garland", "german", "god", "gold", "golden", "green", "greenwood", "hail", "harrow",
    "hermitage", "highland", "hillside", "hit", "holiday", "homestead", "horn", "humble", "hurricane", "imperial",
    "independence", "interior", "jam", "keystone", "lakeside", "largo", "laurel", "lens", "liberty", "male", "man",
    "manage", "mango", "marina", "maritime", "march", "mary", "mascot", "meridian", "mesa", "midland", "midway", "mile",
    "mine", "mission", "mobile", "moss", "much", "mustang", "nice", "normal", "north", "northern", "oceanside",
    "officer", "opportunity", "oral", "orange", "oriental", "panorama", "papa", "papaya", "paradise", "paramount",
    "pearl", "pen", "plantation", "plateau", "plaque", "plunge", "police", "pool", "pop", "providence", "punch",
    "reading", "republic", "reservoir", "retreat", "revere", "rich", "riverside", "rouge", "sale", "salt", "same",
    "sandy", "save", "savage", "say", "south", "southern", "sparks", "split", "spring", "stoke", "sud", "summit",
    "sunrise", "sunset", "superior", "sur", "surprise", "tank", "temple", "tequila", "terrace", "than", "time",
    "trinity", "troy", "turbo", "union", "unity", "university", "upland", "uptown", "us", "vale", "valley", "van",
    "vineyard", "vista", "walnut", "wedding", "west", "western", "woodland", "yoga", "young",
  ]
}
