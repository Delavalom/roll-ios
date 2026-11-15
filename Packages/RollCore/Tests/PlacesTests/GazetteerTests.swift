import Foundation
@testable import Places
import Testing

// Public places only (GeoNames data): no coordinate here comes from anyone's library.
struct GazetteerTests {
  let g: Gazetteer

  init() throws { g = try Gazetteer.load() }

  @Test func loadsTheBundledData() {
    #expect(g.cityCount > 30_000)
    #expect(g.countryCount > 240)
    #expect(g.countryName(code: "PR") == "Puerto Rico")
    #expect(g.countryName(code: "pr") == "Puerto Rico")
    #expect(g.countryName(code: "ZZ") == nil)
  }

  @Test func foldsLikeQueries() {
    #expect(Gazetteer.fold("Bayamón") == "bayamon")
    #expect(Gazetteer.fold("Martha's  Vineyard!") == "marthas vineyard")
    #expect(Gazetteer.fold("São-Paulo") == "sao paulo")
    #expect(Gazetteer.fold("  ") == "")
  }

  @Test func nearestNamesTheCityDivisionAndCountry() throws {
    let sj = try #require(g.nearest(latitude: 18.4663, longitude: -66.1057))
    #expect(sj.city == "San Juan")
    #expect(sj.countryCode == "PR")
    #expect(sj.country == "Puerto Rico")
    #expect(sj.distanceKm < 1)
    let paris = try #require(g.nearest(latitude: 48.8566, longitude: 2.3522))
    #expect(paris.city == "Paris")
    #expect(paris.countryCode == "FR")
    #expect(paris.admin1 == "Île-de-France")
    // Across the antimeridian: Fiji's Suva from the other side of 180°.
    let suva = try #require(g.nearest(latitude: -18.14, longitude: 178.44))
    #expect(suva.countryCode == "FJ")
  }

  @Test func nearestRespectsItsLimit() {
    // The middle of the South Pacific.
    #expect(g.nearest(latitude: -40, longitude: -130) == nil)
    #expect(g.nearest(latitude: -40, longitude: -130, maxKm: 20_000) != nil)
    #expect(g.nearest(latitude: .nan, longitude: 0) == nil)
  }

  @Test func nearestAgreesWithABruteForceScan() {
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<200 {
      let lat = Double.random(in: -60...70, using: &rng), lon = Double.random(in: -180..<180, using: &rng)
      let fast = g.nearest(latitude: lat, longitude: lon, maxKm: 500)
      let slow = g.bruteForceNearest(latitude: lat, longitude: lon, maxKm: 500)
      #expect(fast?.city == slow?.city, "\(lat), \(lon)")
      if let fast, let slow { #expect(abs(fast.distanceKm - slow.distanceKm) < 1e-6) }
    }
  }

  @Test func matchesPlaceNamesLongestFirst() {
    let m = g.match(["San", "Juan", "Puerto", "Rico"])
    #expect(m.contains { $0.kind == .city && $0.name == "San Juan" && $0.countryCode == "PR" && $0.terms == 0..<2 })
    #expect(m.contains { $0.kind == .country && $0.countryCode == "PR" && $0.terms == 2..<4 })
    // Cities called San Juan elsewhere too, most populous first; also divisions called San Juan (Argentina, PR).
    let cities = m.filter { $0.terms == 0..<2 && $0.kind == .city }
    #expect(cities.count > 1)
    #expect(cities.first?.countryCode == "PR")
    #expect(m.contains { $0.terms == 0..<2 && $0.kind == .admin1 })
  }

  @Test func matchesEnglishAndSpanishNames() {
    #expect(g.match(["alemania"]).contains { $0.kind == .country && $0.countryCode == "DE" })
    #expect(g.match(["nueva", "york"]).contains { $0.kind == .city && $0.name == "New York City" })
    #expect(g.match(["estados", "unidos"]).contains { $0.countryCode == "US" && $0.kind == .country })
    #expect(g.match(["usa"]).contains { $0.countryCode == "US" && $0.kind == .country })
    #expect(g.match(["florida"]).contains { $0.kind == .admin1 && $0.admin1Code == "US.FL" })
    #expect(g.match(["bayamón"]).contains { $0.kind == .city && $0.countryCode == "PR" })
  }

  @Test func countryCodesOnlyInCapitals() {
    #expect(g.match(["PR"]).map(\.countryCode) == ["PR"])
    #expect(g.match(["pr"]).isEmpty)
    #expect(g.match(["us"]).isEmpty)
  }

  @Test func everydayWordsAreNotPlaces() {
    for word in ["wedding", "nice", "mission", "paradise", "sunset", "beach", "dog", "2024", "of", "me"] {
      #expect(g.match([word]).isEmpty, "\(word)")
    }
    #expect(g.match(["beach", "in", "paris"]).allSatisfy { $0.terms == 2..<3 })
  }

  @Test func membershipByRadiusDivisionAndCountry() throws {
    let sj = try #require(g.match(["san", "juan"]).first { $0.countryCode == "PR" && $0.kind == .city })
    #expect(g.contains(sj, latitude: 18.43, longitude: -66.07))  // ~5 km away
    #expect(!g.contains(sj, latitude: 18.01, longitude: -66.61))  // Ponce, ~75 km
    let pr = try #require(g.match(["puerto", "rico"]).first { $0.kind == .country })
    #expect(g.contains(pr, latitude: 18.01, longitude: -66.61))
    #expect(!g.contains(pr, latitude: 25.77, longitude: -80.19))  // Miami
    let us = try #require(g.match(["usa"]).first)
    #expect(g.contains(us, latitude: 25.77, longitude: -80.19))
    #expect(!g.contains(us, latitude: 18.01, longitude: -66.61))  // Puerto Rico is its own code
    let fl = try #require(g.match(["florida"]).first { $0.admin1Code == "US.FL" })
    #expect(g.match(["florida"]).contains { $0.admin1Code?.hasPrefix("UY.") == true })  // Uruguay has one too
    #expect(g.contains(fl, latitude: 25.77, longitude: -80.19))
    #expect(!g.contains(fl, latitude: 33.75, longitude: -84.39))  // Atlanta
  }

  @Test func cityRadiusGrowsWithPopulation() {
    #expect(g.cityRadiusKm(population: 15_000) == 10)
    #expect(abs(g.cityRadiusKm(population: 1_500_000) - 26) < 1e-9)
    #expect(g.cityRadiusKm(population: 100) == 10)
  }

  @Test func locatorAgreesWithTheGazetteerAndIsFast() throws {
    let pr = try #require(g.match(["puerto", "rico"]).first { $0.kind == .country })
    let fl = try #require(g.match(["florida"]).first { $0.admin1Code == "US.FL" })
    let locator = PlaceLocator(gazetteer: g)
    var rng = SystemRandomNumberGenerator()
    // A synthetic library: clusters around two public city centers plus scattered points.
    var points: [(Double, Double)] = []
    for i in 0..<30_000 {
      switch i % 3 {
      case 0: points.append((18.4 + .random(in: -0.2...0.2, using: &rng), -66.1 + .random(in: -0.3...0.3, using: &rng)))
      case 1: points.append((25.8 + .random(in: -0.2...0.2, using: &rng), -80.2 + .random(in: -0.2...0.2, using: &rng)))
      default: points.append((.random(in: -50...60, using: &rng), .random(in: -180..<180, using: &rng)))
      }
    }
    for (lat, lon) in points.prefix(500) {
      #expect(locator.contains(pr, latitude: lat, longitude: lon) == g.contains(pr, latitude: lat, longitude: lon))
      #expect(locator.contains(fl, latitude: lat, longitude: lon) == g.contains(fl, latitude: lat, longitude: lon))
    }
    let start = ContinuousClock.now
    var inPR = 0
    for (lat, lon) in points where locator.contains(pr, latitude: lat, longitude: lon) { inPR += 1 }
    let elapsed = ContinuousClock.now - start
    #expect(inPR >= 9_000)
    #expect(elapsed < .seconds(3), "\(elapsed)")  // Debug build; Release is far faster
  }
}

extension Gazetteer {
  /// Every city checked (the reference for the grid).
  func bruteForceNearest(latitude: Double, longitude: Double, maxKm: Double) -> Place? {
    var best: Place?
    for i in 0..<cityCount {
      let p = place(i, km: Gazetteer.distanceKm(latitude, longitude, latitudes[i], longitudes[i]))
      if p.distanceKm <= maxKm, best.map({ p.distanceKm < $0.distanceKm }) ?? true { best = p }
    }
    return best
  }
}
