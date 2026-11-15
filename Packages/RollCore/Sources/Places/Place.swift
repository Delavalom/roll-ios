import Foundation

/// The populated place nearest a coordinate (`Gazetteer.nearest`).
public struct Place: Sendable, Equatable {
  public var city: String
  /// First-level division (state, province, region) name; nil when GeoNames has none for the city.
  public var admin1: String?
  /// "CC.code" (e.g. "US.FL", "PR.127").
  public var admin1Code: String?
  public var country: String
  /// ISO 3166-1 alpha-2 ("PR" for Puerto Rico, which GeoNames lists as a country).
  public var countryCode: String
  public var latitude: Double
  public var longitude: Double
  public var population: Int
  /// Great-circle distance from the asked coordinate to the city's center.
  public var distanceKm: Double

  public init(city: String, admin1: String?, admin1Code: String?, country: String, countryCode: String,
              latitude: Double, longitude: Double, population: Int, distanceKm: Double) {
    self.city = city; self.admin1 = admin1; self.admin1Code = admin1Code; self.country = country
    self.countryCode = countryCode; self.latitude = latitude; self.longitude = longitude
    self.population = population; self.distanceKm = distanceKm
  }
}

/// A run of query words that names a place (`Gazetteer.match`), with the test a coordinate must pass to be in it.
public struct PlaceMatch: Sendable, Hashable, Codable {
  public enum Kind: String, Sendable, Codable { case country, admin1, city }

  public var kind: Kind
  /// The place's name as GeoNames writes it ("San Juan", "Florida", "Puerto Rico").
  public var name: String
  /// Which of the terms passed to `match` name it.
  public var terms: Range<Int>
  public var countryCode: String
  /// "CC.code" for an admin1 or a city with one.
  public var admin1Code: String?
  /// A city's center.
  public var latitude: Double?
  public var longitude: Double?
  public var population: Int
  /// A city's radius (`Gazetteer.Options.cityRadiusKm`).
  public var radiusKm: Double?

  public init(kind: Kind, name: String, terms: Range<Int>, countryCode: String, admin1Code: String? = nil,
              latitude: Double? = nil, longitude: Double? = nil, population: Int = 0, radiusKm: Double? = nil) {
    self.kind = kind; self.name = name; self.terms = terms; self.countryCode = countryCode
    self.admin1Code = admin1Code; self.latitude = latitude; self.longitude = longitude
    self.population = population; self.radiusKm = radiusKm
  }
}
