import Foundation
import Places
@testable import Ranking
import Testing

/// Sunday 15 November 2026, noon, in a time zone without daylight saving.
private let calendar: Calendar = {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "America/Puerto_Rico")!
  return c
}()
private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Double {
  calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970
}
private let now = Date(timeIntervalSince1970: day(2026, 11, 15, 12))
private let gazetteer = try! Gazetteer.load()

private func parse(_ text: String, options: QueryUnderstanding.Options = .init(), places: Bool = true)
  -> QueryUnderstanding.Understanding {
  QueryUnderstanding.parse(text, now: now, calendar: calendar, gazetteer: places ? gazetteer : nil, options: options)
}

/// `[start, end)` of each absolute range.
private func spans(_ u: QueryUnderstanding.Understanding) -> [[Double]] {
  u.dateRanges.map { [$0.lowerBound, ($0.upperBound + 0.001).rounded()] }
}

struct QueryUnderstandingDateTests {
  struct Case: Sendable, CustomTestStringConvertible {
    var query: String
    var semantic: String
    var ranges: [[Double]]
    var testDescription: String { query }
  }

  static let absolute: [Case] = [
    Case(query: "beach 2024", semantic: "beach", ranges: [[day(2024, 1, 1), day(2025, 1, 1)]]),
    Case(query: "photos in 2023", semantic: "photos", ranges: [[day(2023, 1, 1), day(2024, 1, 1)]]),
    Case(query: "dogs this year", semantic: "dogs", ranges: [[day(2026, 1, 1), day(2027, 1, 1)]]),
    Case(query: "concert last year", semantic: "concert", ranges: [[day(2025, 1, 1), day(2026, 1, 1)]]),
    Case(query: "el año pasado", semantic: "", ranges: [[day(2025, 1, 1), day(2026, 1, 1)]]),
    Case(query: "food last month", semantic: "food", ranges: [[day(2026, 10, 1), day(2026, 11, 1)]]),
    Case(query: "el mes pasado", semantic: "", ranges: [[day(2026, 10, 1), day(2026, 11, 1)]]),
    Case(query: "gym last week", semantic: "gym", ranges: [[day(2026, 11, 8), day(2026, 11, 15)]]),
    Case(query: "yesterday", semantic: "", ranges: [[day(2026, 11, 14), day(2026, 11, 15)]]),
    Case(query: "ayer", semantic: "", ranges: [[day(2026, 11, 14), day(2026, 11, 15)]]),
    Case(query: "today", semantic: "", ranges: [[day(2026, 11, 15), day(2026, 11, 16)]]),
    Case(query: "last summer", semantic: "", ranges: [[day(2026, 6, 1), day(2026, 9, 1)]]),
    Case(query: "el verano pasado", semantic: "", ranges: [[day(2026, 6, 1), day(2026, 9, 1)]]),
    Case(query: "this summer", semantic: "", ranges: [[day(2026, 6, 1), day(2026, 9, 1)]]),
    Case(query: "snow last winter", semantic: "snow", ranges: [[day(2025, 12, 1), day(2026, 3, 1)]]),
    Case(query: "last spring", semantic: "", ranges: [[day(2026, 3, 1), day(2026, 6, 1)]]),
    Case(query: "last fall", semantic: "", ranges: [[day(2025, 9, 1), day(2025, 12, 1)]]),  // fall 2026 isn't over
    Case(query: "last christmas", semantic: "christmas", ranges: [[day(2025, 12, 24), day(2025, 12, 27)]]),
    Case(query: "june 2024", semantic: "", ranges: [[day(2024, 6, 1), day(2024, 7, 1)]]),
    Case(query: "junio de 2023", semantic: "", ranges: [[day(2023, 6, 1), day(2023, 7, 1)]]),
    Case(query: "may 2024", semantic: "", ranges: [[day(2024, 5, 1), day(2024, 6, 1)]]),
    Case(query: "summer 2022", semantic: "", ranges: [[day(2022, 6, 1), day(2022, 9, 1)]]),
    Case(query: "verano 2022", semantic: "", ranges: [[day(2022, 6, 1), day(2022, 9, 1)]]),
    Case(query: "winter 2022", semantic: "",
         ranges: [[day(2022, 1, 1), day(2022, 3, 1)], [day(2022, 12, 1), day(2023, 1, 1)]]),
    Case(query: "christmas 2023", semantic: "christmas", ranges: [[day(2023, 12, 24), day(2023, 12, 27)]]),
    Case(query: "navidad 2023", semantic: "navidad", ranges: [[day(2023, 12, 24), day(2023, 12, 27)]]),
    Case(query: "new year's eve 2023", semantic: "new year's eve", ranges: [[day(2023, 12, 31), day(2024, 1, 2)]]),
    Case(query: "thanksgiving 2026", semantic: "thanksgiving", ranges: [[day(2026, 11, 26), day(2026, 11, 30)]]),
    Case(query: "easter 2025", semantic: "easter", ranges: [[day(2025, 4, 18), day(2025, 4, 22)]]),
    Case(query: "beach 2023 2024", semantic: "beach",
         ranges: [[day(2023, 1, 1), day(2024, 1, 1)], [day(2024, 1, 1), day(2025, 1, 1)]]),
  ]

  @Test(arguments: absolute) func absoluteDates(_ c: Case) {
    let u = parse(c.query)
    #expect(u.semanticText == c.semantic)
    #expect(spans(u) == c.ranges)
    #expect(u.anyYearWindows.isEmpty)
  }

  struct AnyYear: Sendable, CustomTestStringConvertible {
    var query: String
    var semantic: String
    var inside: [Double]
    var outside: [Double]
    var testDescription: String { query }
  }

  static let anyYear: [AnyYear] = [
    AnyYear(query: "june", semantic: "", inside: [day(2019, 6, 3), day(2026, 6, 30, 23)],
            outside: [day(2019, 7, 1), day(2019, 5, 31, 23)]),
    AnyYear(query: "fotos de enero", semantic: "fotos", inside: [day(2011, 1, 9)], outside: [day(2011, 2, 1)]),
    AnyYear(query: "diciembre", semantic: "", inside: [day(2020, 12, 31, 23)], outside: [day(2021, 1, 1, 1)]),
    AnyYear(query: "in may", semantic: "", inside: [day(2018, 5, 20)], outside: [day(2018, 6, 2)]),
    AnyYear(query: "christmas", semantic: "christmas", inside: [day(2019, 12, 24), day(2019, 12, 26, 23)],
            outside: [day(2019, 12, 27, 1), day(2019, 12, 23, 22)]),
    AnyYear(query: "navidad", semantic: "navidad", inside: [day(2015, 12, 25)], outside: [day(2015, 12, 1)]),
    AnyYear(query: "christmas eve", semantic: "christmas eve", inside: [day(2015, 12, 24, 20)], outside: [day(2015, 12, 25, 1)]),
    AnyYear(query: "new year's eve", semantic: "new year's eve", inside: [day(2019, 12, 31, 22), day(2020, 1, 1, 2)],
            outside: [day(2019, 12, 30)]),
    AnyYear(query: "nochevieja", semantic: "nochevieja", inside: [day(2019, 12, 31, 22)], outside: [day(2019, 12, 29)]),
    AnyYear(query: "new year's day", semantic: "new year's day", inside: [day(2020, 1, 1, 12)], outside: [day(2019, 12, 31, 12)]),
    AnyYear(query: "halloween party", semantic: "halloween party", inside: [day(2021, 10, 31, 21), day(2021, 11, 1, 1)],
            outside: [day(2021, 10, 29)]),
    AnyYear(query: "thanksgiving", semantic: "thanksgiving", inside: [day(2026, 11, 26, 15), day(2024, 11, 28, 15)],
            outside: [day(2024, 11, 21, 15)]),
    AnyYear(query: "4th of july fireworks", semantic: "4th of july fireworks", inside: [day(2022, 7, 4, 21), day(2022, 7, 5, 0)],
            outside: [day(2022, 7, 3)]),
    AnyYear(query: "july 4th", semantic: "july 4th", inside: [day(2022, 7, 4, 21)], outside: [day(2022, 7, 10)]),
    AnyYear(query: "valentine's day dinner", semantic: "valentine's day dinner", inside: [day(2023, 2, 14, 20)],
            outside: [day(2023, 2, 15, 1)]),
    AnyYear(query: "easter", semantic: "easter", inside: [day(2025, 4, 19), day(2024, 3, 31)], outside: [day(2025, 4, 10)]),
    AnyYear(query: "semana santa", semantic: "semana santa", inside: [day(2025, 4, 20)], outside: [day(2025, 5, 20)]),
  ]

  @Test(arguments: anyYear) func anyYearWindows(_ c: AnyYear) {
    let u = parse(c.query)
    #expect(u.semanticText == c.semantic)
    #expect(u.dateRanges.isEmpty)
    #expect(!u.anyYearWindows.isEmpty)
    for t in c.inside { #expect(u.matchesDate(t, calendar: calendar), "inside \(t)") }
    for t in c.outside { #expect(!u.matchesDate(t, calendar: calendar), "outside \(t)") }
    #expect(!u.matchesDate(nil, calendar: calendar), "an undated photo never passes a date filter")
  }

  @Test(arguments: ["may", "march", "summer", "spring", "fall", "mayo", "1234", "2099", "dog", "trip"])
  func wordsThatStayWords(_ query: String) {
    let u = parse(query)
    #expect(!u.hasDateFilter)
    #expect(u.semanticText == query)
    #expect(u.matchesDate(nil, calendar: calendar))
  }

  @Test func optionsTurnOnBareSeasonsKeepHolidayWordsAndFlipHemispheres() {
    var o = QueryUnderstanding.Options()
    o.bareSeasonIsDate = true
    #expect(parse("summer", options: o).anyYearWindows == [.days(startMonth: 6, startDay: 1, endMonth: 9, endDay: 1)])
    o.southernHemisphere = true
    #expect(parse("summer", options: o).anyYearWindows == [.days(startMonth: 12, startDay: 1, endMonth: 3, endDay: 1)])
    var drop = QueryUnderstanding.Options()
    drop.keepHolidayWords = false
    let u = parse("christmas tree 2023", options: drop)
    #expect(u.semanticText == "tree" && u.hasDateFilter)
    #expect(parse("christmas 2023", options: drop).isFilterOnly)
  }

  struct Kept: Sendable, CustomTestStringConvertible {
    var query: String
    var semantic: String
    var testDescription: String { query }
  }

  /// Holiday words filter *and* stay embedded (the find eval's "christmas 2023" ranked by time scored P@20 0.2);
  /// month, season, year and relative words only filter.
  static let kept: [Kept] = [
    Kept(query: "christmas 2023", semantic: "christmas"),
    Kept(query: "Christmas morning 2023", semantic: "Christmas morning"),
    Kept(query: "la navidad pasada", semantic: "navidad"),
    Kept(query: "this halloween", semantic: "halloween"),
    Kept(query: "thanksgiving dinner last year", semantic: "thanksgiving dinner"),
    Kept(query: "new year 2024", semantic: "new year"),
    Kept(query: "valentines in 2022", semantic: "valentines"),
    Kept(query: "easter sunday 2025", semantic: "easter sunday"),
    Kept(query: "fourth of july 2021", semantic: "fourth of july"),
    Kept(query: "beach june 2024", semantic: "beach"),
    Kept(query: "snow last winter", semantic: "snow"),
    Kept(query: "summer 2022", semantic: ""),
    Kept(query: "dogs this year", semantic: "dogs"),
    Kept(query: "gym last week", semantic: "gym"),
  ]

  @Test(arguments: kept) func holidayWordsFilterAndStay(_ c: Kept) {
    let u = parse(c.query)
    #expect(u.hasDateFilter)
    #expect(u.semanticText == c.semantic)
  }

  @Test func filterOnlyQueries() {
    #expect(parse("photos from 2024").isFilterOnly)
    #expect(parse("trip 2024").isFilterOnly)
    #expect(!parse("vacaciones navidad").isFilterOnly)  // the holiday word stays: embedded, filtered to its days
    #expect(!parse("screenshots 2024").isFilterOnly)  // a kind word still means something
    #expect(!parse("beach 2024").isFilterOnly)
    #expect(!parse("trip").isFilterOnly)  // no filter: embed it
  }

  @Test func holidayHelpers() {
    #expect(QueryUnderstanding.thanksgivingDay(year: 2026, calendar: calendar) == 26)
    #expect(QueryUnderstanding.thanksgivingDay(year: 2024, calendar: calendar) == 28)
    #expect(QueryUnderstanding.easter(year: 2025) == (4, 20))
    #expect(QueryUnderstanding.easter(year: 2024) == (3, 31))
  }
}

struct QueryUnderstandingPlaceTests {
  @Test func placesAndDatesTogether() {
    let u = parse("San Juan Puerto Rico 2024")
    #expect(u.semanticText == "")
    #expect(u.placeSpans.count == 2)
    #expect(u.placeSpans.allSatisfy { $0.clause == 0 })  // adjacent places refine each other
    #expect(u.placeSpans[1].matches.contains { $0.kind == .country && $0.countryCode == "PR" })
    #expect(spans(u) == [[day(2024, 1, 1), day(2025, 1, 1)]])
    #expect(u.isFilterOnly)
    #expect(Set(u.removedWords) == ["san", "juan", "puerto", "rico", "2024"])
  }

  @Test func connectorsGoWithThePlaceAndTripStays() {
    let u = parse("trip to Puerto Rico")
    #expect(u.semanticText == "trip")
    #expect(u.removedWords == ["to", "puerto", "rico"])
    #expect(u.isFilterOnly)
    #expect(parse("beach in Paris").semanticText == "beach")
    #expect(parse("fotos de playa en Alemania").semanticText == "fotos de playa")
  }

  @Test func keptPlaceWordsFilterAndStayEmbedded() {
    var o = QueryUnderstanding.Options()
    o.keepPlaceWords = true
    let trip = parse("trip to Puerto Rico 2024", options: o)
    #expect(trip.semanticText == "trip to Puerto Rico")
    #expect(trip.hasPlaceFilter && trip.hasDateFilter && !trip.isFilterOnly)
    #expect(trip.removedWords == ["2024"])
    let only = parse("Puerto Rico", options: o)
    #expect(only.semanticText == "Puerto Rico" && only.hasPlaceFilter && !only.isFilterOnly)
    // A place nobody photographed gives its words back either way.
    let resolved = parse("beach in Paris", options: o)
      .resolvingPlaces(locations: [(18.45, -66.07)], locator: PlaceLocator(gazetteer: gazetteer), minimumPhotos: 1)
    #expect(resolved.semanticText == "beach in Paris" && !resolved.hasPlaceFilter)
  }

  @Test func conjunctionsMakeAlternatives() {
    let u = parse("Spain and Portugal")
    #expect(u.semanticText == "")
    #expect(u.placeSpans.map(\.clause) == [0, 1])
  }

  @Test func countryCodesInCapitalsAndEverydayWords() {
    #expect(parse("PR beach").places.map(\.countryCode) == ["PR"])
    #expect(parse("pr beach").places.isEmpty)
    #expect(parse("wedding").places.isEmpty)
    #expect(parse("beach in Paris", places: false).semanticText == "beach in Paris")
  }

  @Test func placesNobodyPhotographedStayWords() throws {
    let u = parse("beach in Paris")
    let locator = PlaceLocator(gazetteer: gazetteer)
    // A synthetic library around San Juan only.
    let library = (0..<50).map { (latitude: 18.45 + Double($0) * 0.0005, longitude: -66.07) }
    let resolved = u.resolvingPlaces(locations: library, locator: locator, minimumPhotos: 1)
    #expect(resolved.semanticText == "beach in Paris")
    #expect(!resolved.hasPlaceFilter)

    let sj = parse("San Juan Puerto Rico").resolvingPlaces(locations: library, locator: locator, minimumPhotos: 3)
    #expect(sj.placeSpans.count == 2)
    #expect(sj.placeSpans[0].matches.allSatisfy { $0.countryCode == "PR" })  // the other San Juans are gone
    #expect(sj.matchesPlace(latitude: 18.45, longitude: -66.07, locator: locator))
    #expect(!sj.matchesPlace(latitude: 18.01, longitude: -66.61, locator: locator))  // Ponce: PR, not San Juan
    #expect(!sj.matchesPlace(latitude: nil, longitude: nil, locator: locator))
  }

  @Test func alternativesPassEitherPlace() {
    let u = parse("Spain or Portugal")
    let locator = PlaceLocator(gazetteer: gazetteer)
    #expect(u.matchesPlace(latitude: 40.42, longitude: -3.70, locator: locator))  // Madrid
    #expect(u.matchesPlace(latitude: 38.72, longitude: -9.14, locator: locator))  // Lisbon
    #expect(!u.matchesPlace(latitude: 48.86, longitude: 2.35, locator: locator))  // Paris
  }
}
