import Foundation

/// Roll's offline gazetteer: GeoNames' cities of 15,000 people or more, countries and first-level divisions, with
/// English and Spanish alternate names for countries, divisions and big cities (CC-BY 4.0; `Resources/NOTICE`; built by
/// `scripts/make_places.py`). Nothing here touches the network.
///
/// - `nearest(latitude:longitude:)`: the nearest city, through a 1° grid (rings searched outward until no closer city
///   can exist), so tens of thousands of lookups take milliseconds.
/// - `match(_:)`: runs of up to `Options.maxWords` query words that name a place, longest first, left to right.
/// - `contains(_:latitude:longitude:)`: whether a coordinate is in a matched place. A city is a radius around its center
///   that grows with population; a division or a country is "the nearest city is in it" (a coordinate on a border can
///   land on the wrong side; no polygons ship with the app).
///
/// Load it once (`load()` caches it): parsing the 1.9 MB of text takes tens of milliseconds.
public final class Gazetteer: Sendable {
  public struct Options: Sendable, Equatable {
    /// A city of 15,000 people reaches `cityBaseRadiusKm`; each 10x more people adds `cityRadiusPerDecadeKm`
    /// (15k: 10 km, 150k: 18 km, 1.5M: 26 km, 15M: 34 km). Starting values: a metro area's photos (beaches, airport,
    /// suburbs) should count as the city, a neighbouring town 30 km away shouldn't. The eval tunes them.
    public var cityBaseRadiusKm: Double = 10
    public var cityRadiusPerDecadeKm: Double = 8
    /// Division and country tests use the nearest city within this distance (farther: not in any). 300 km covers the
    /// emptiest settled regions between 15k-people towns without reaching across an ocean to another country.
    public var regionMaxKm: Double = 300
    /// `nearest`'s default limit.
    public var nearestMaxKm: Double = 200
    /// Longest name, in words, `match` tries ("estado libre asociado de puerto rico" is 6).
    public var maxWords = 6
    /// At most this many same-named cities per match, most populous first ("San Juan" has 6).
    public var maxCitiesPerName = 8
    /// One-word names that are everyday words people put in photo queries ("wedding" is a Berlin locality, "nice"
    /// a French city, "mission" a Texas one). They never match alone; two-word names containing them still do.
    public var commonWords: Set<String> = Gazetteer.defaultCommonWords

    public init() {}
  }

  enum Entry: Sendable, Hashable {
    case country(Int32)
    case admin1(Int32)
    case city(Int32)
  }

  public let options: Options

  let countryCodes: [String]
  let countryNames: [String]
  let countryIndex: [String: Int32]
  /// Per country: (minLat, maxLat, minLon, maxLon) of its cities, widened by 3°: a quick "can't be in it".
  let countryBoxes: [(Double, Double, Double, Double)?]
  let admin1Codes: [String]
  let admin1Names: [String]
  let admin1Index: [String: Int32]
  let cityNames: [String]
  let cityCountry: [Int32]
  let cityAdmin1: [Int32]
  let latitudes: [Double]
  let longitudes: [Double]
  let populations: [Int32]
  let grid: [[Int32]]
  let names: [String: [Entry]]

  // MARK: - Loading

  private static let bundled = Result<Gazetteer, any Error> {
    guard let url = Bundle.module.url(forResource: "places", withExtension: "z") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Gazetteer(compressed: try Data(contentsOf: url))
  }

  /// The bundled gazetteer, parsed once per process.
  public static func load() throws -> Gazetteer { try bundled.get() }

  /// `places.z` contents: raw DEFLATE of the text `scripts/make_places.py` writes.
  public convenience init(compressed: Data, options: Options = Options()) throws {
    let text = try (compressed as NSData).decompressed(using: .zlib) as Data
    self.init(text: String(decoding: text, as: UTF8.self), options: options)
  }

  /// Parses the uncompressed text (tests build small gazetteers this way).
  public init(text: String, options: Options = Options()) {
    self.options = options
    var countryCodes: [String] = [], countryNames: [String] = [], countryIndex: [String: Int32] = [:]
    var admin1Codes: [String] = [], admin1Names: [String] = [], admin1Index: [String: Int32] = [:]
    var cityNames: [String] = [], cityCountry: [Int32] = [], cityAdmin1: [Int32] = []
    var latitudes: [Double] = [], longitudes: [Double] = [], populations: [Int32] = []
    var names: [String: [Entry]] = [:]
    func add(_ name: Substring, _ entry: Entry) {
      let key = Self.fold(String(name))
      guard !key.isEmpty else { return }
      if names[key]?.contains(entry) != true { names[key, default: []].append(entry) }
    }

    var section = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.hasPrefix("#") { section = String(line); continue }
      let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
      switch section {
      case "#countries" where cols.count >= 4:
        let i = Int32(countryCodes.count)
        countryCodes.append(String(cols[0]))
        countryNames.append(String(cols[2]))
        countryIndex[String(cols[0])] = i
        add(cols[2], .country(i))
        for alt in cols[3].split(separator: "|") { add(alt, .country(i)) }
      case "#admin1" where cols.count >= 4:
        let i = Int32(admin1Codes.count)
        admin1Codes.append(String(cols[0]))
        admin1Names.append(String(cols[1]))
        admin1Index[String(cols[0])] = i
        add(cols[1], .admin1(i))
        add(cols[2], .admin1(i))
        for alt in cols[3].split(separator: "|") { add(alt, .admin1(i)) }
      case "#cities" where cols.count >= 8:
        guard let lat = Double(cols[5]), let lon = Double(cols[6]) else { continue }
        let i = Int32(cityNames.count)
        let country = String(cols[3])
        cityNames.append(String(cols[0]))
        cityCountry.append(countryIndex[country] ?? -1)
        cityAdmin1.append(admin1Index["\(country).\(cols[4])"] ?? -1)
        latitudes.append(lat)
        longitudes.append(lon)
        populations.append(Int32(clamping: Int(cols[7]) ?? 0))
        add(cols[0], .city(i))
        add(cols[1], .city(i))
        for alt in cols[2].split(separator: "|") { add(alt, .city(i)) }
      default:
        continue
      }
    }

    var grid = [[Int32]](repeating: [], count: 180 * 360)
    var boxes = [(Double, Double, Double, Double)?](repeating: nil, count: countryCodes.count)
    for i in 0..<cityNames.count {
      grid[Self.cell(latitudes[i], longitudes[i])].append(Int32(i))
      let c = Int(cityCountry[i])
      guard c >= 0 else { continue }
      let (lat, lon) = (latitudes[i], longitudes[i])
      if let b = boxes[c] {
        boxes[c] = (min(b.0, lat), max(b.1, lat), min(b.2, lon), max(b.3, lon))
      } else {
        boxes[c] = (lat, lat, lon, lon)
      }
    }
    self.countryBoxes = boxes.map { $0.map { ($0.0 - 3, $0.1 + 3, $0.2 - 3, $0.3 + 3) } }
    self.countryCodes = countryCodes; self.countryNames = countryNames; self.countryIndex = countryIndex
    self.admin1Codes = admin1Codes; self.admin1Names = admin1Names; self.admin1Index = admin1Index
    self.cityNames = cityNames; self.cityCountry = cityCountry; self.cityAdmin1 = cityAdmin1
    self.latitudes = latitudes; self.longitudes = longitudes; self.populations = populations
    self.grid = grid
    self.names = names
  }

  public var cityCount: Int { cityNames.count }
  public var countryCount: Int { countryCodes.count }

  /// The country's name ("Puerto Rico" for "PR"); nil for an unknown code.
  public func countryName(code: String) -> String? {
    countryIndex[code.uppercased()].map { countryNames[Int($0)] }
  }

  // MARK: - Folding

  /// How names and query words are compared: diacritics and case folded ("Bayamón" → "bayamon"), apostrophes dropped
  /// ("Martha's" → "marthas"), anything else that isn't a letter or digit becomes a space, spaces collapsed.
  public static func fold(_ text: String) -> String {
    let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    var out = ""
    out.reserveCapacity(folded.count)
    var pendingSpace = false
    for ch in folded {
      if ch == "'" || ch == "\u{2019}" { continue }
      if ch.isLetter || ch.isNumber {
        if pendingSpace && !out.isEmpty { out.append(" ") }
        pendingSpace = false
        out.append(ch)
      } else {
        pendingSpace = true
      }
    }
    return out
  }
}
