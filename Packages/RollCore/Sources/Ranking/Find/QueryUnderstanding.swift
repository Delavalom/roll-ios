import Foundation
import Places

/// Reads a typed query for the words that only say *when* or *where* ("2024", "last summer", "Christmas", "en
/// diciembre", "Puerto Rico") and turns them into filters, so only the rest is embedded (Find V2). Pure: the caller
/// passes the clock, the calendar (its time zone decides where a day starts) and the gazetteer.
///
/// - **Dates.** Years ("2024", "in 2023"); "this/last year", "last month", "last week", "yesterday", "today"; "last/this
///   summer|winter|spring|fall"; month names with a year ("June 2024", "junio de 2023": that month) or without one
///   ("June": June of any year); "summer 2022"; holidays (Christmas, Christmas Eve, New Year's Eve/Day, Halloween,
///   Thanksgiving, July 4th, Valentine's, Easter) as day windows in any year unless a year is given; Spanish basics
///   (verano, invierno, navidad, enero…diciembre, el año pasado). Calendar units are whole units: "last month" on
///   15 November is all of October, "last week" the previous calendar week. Seasons are meteorological (summer =
///   June–August) and northern unless `Options.southernHemisphere`.
/// - **Places.** Runs of the remaining words that name a gazetteer place (`Gazetteer.match`). Adjacent places refine
///   each other ("San Juan, Puerto Rico": both must hold); places joined by "and"/"or"/"y"/"o" are alternatives
///   ("Spain and Portugal"). Whether a place filters at all is decided against the library
///   (`Understanding.resolvingPlaces`): a name nobody photographed ("wedding" was a Berlin district) stays a word.
/// - **What stays.** Everything else, in order, is `semanticText`. "trip", "vacation" stay; a query whose words are
///   only those (or "photos") plus a date or place is `isFilterOnly`: everything in that window, by time.
///
/// Ambiguous words need a hint before they count as dates: "may", "march", "mayo" need a year, "in"/"en"/"last"/"this";
/// a bare season ("summer", "spring") stays a word unless `Options.bareSeasonIsDate` (it describes a scene as often as
/// a date).
public enum QueryUnderstanding {
  public struct Options: Sendable, Equatable, Codable {
    /// Four-digit numbers from `minYear` to the current year + `maxYearsAhead` are years; others are words.
    public var minYear = 1900
    public var maxYearsAhead = 1
    /// "summer" alone filters to June–August of any year (off: it stays a word, like "beach").
    public var bareSeasonIsDate = false
    /// A holiday filters to its days *and* stays in the embedded text (off: it only filters, so "Christmas" is every
    /// photo taken 24–26 December, by time).
    public var keepHolidayWords = false
    /// Seasons of the southern hemisphere (summer = December–February).
    public var southernHemisphere = false

    public init() {}
  }

  public enum Role: Sendable, Equatable, Codable {
    /// Embedded.
    case semantic
    /// Part of a date expression.
    case date
    /// Part of place span `n` (`Understanding.placeSpans`).
    case place(Int)
    /// A small word that only introduced a date (nil) or place span `n` ("in", "from", "to", "en", "de", or
    /// "and" between two places): removed with it, and back with it if the place doesn't filter.
    case connector(Int?)
  }

  public struct Token: Sendable, Equatable, Codable {
    /// As typed.
    public var text: String
    /// `Gazetteer.fold`ed.
    public var folded: String
    public var role: Role
  }

  /// Days in any year: a month-day window (may wrap into January), or a holiday whose date moves.
  public enum DayWindow: Sendable, Hashable, Codable {
    /// From `startMonth`/`startDay` up to, not including, `endMonth`/`endDay` (an end at or before the start wraps
    /// into the next year: winter is 1 December to 1 March).
    case days(startMonth: Int, startDay: Int, endMonth: Int, endDay: Int)
    /// A whole month (any year).
    case month(Int)
    /// Thanksgiving (4th Thursday of November) to the Sunday after.
    case thanksgiving
    /// Good Friday to Easter Monday (Gregorian Easter).
    case easter

    /// The window that starts in `year`, as seconds since 1970 (end exclusive).
    public func interval(year: Int, calendar: Calendar) -> Range<Double> {
      func day(_ y: Int, _ m: Int, _ d: Int) -> Double {
        calendar.date(from: DateComponents(year: y, month: m, day: d))?.timeIntervalSince1970 ?? 0
      }
      switch self {
      case .days(let sm, let sd, let em, let ed):
        let endYear = (em, ed) <= (sm, sd) ? year + 1 : year
        return day(year, sm, sd)..<day(endYear, em, ed)
      case .month(let m):
        return day(year, m, 1)..<day(m == 12 ? year + 1 : year, m == 12 ? 1 : m + 1, 1)
      case .thanksgiving:
        let thursday = QueryUnderstanding.thanksgivingDay(year: year, calendar: calendar)
        return day(year, 11, thursday)..<day(year, 11, thursday + 4)
      case .easter:
        let (m, d) = QueryUnderstanding.easter(year: year)
        let sunday = day(year, m, d)
        return (sunday - 2 * 86_400)..<(sunday + 2 * 86_400)
      }
    }
  }

  /// One run of words naming places: a coordinate is in it if it is in any of `matches`.
  public struct PlaceSpan: Sendable, Equatable, Codable {
    public var matches: [PlaceMatch]
    /// Spans with the same clause must all hold; any clause will do.
    public var clause: Int
    /// The span's words (`folded`).
    public var words: [String]
  }

  public struct Understanding: Sendable, Equatable, Codable {
    public var text: String
    public var tokens: [Token]
    /// The words to embed, as typed, in order.
    public var semanticText: String
    /// Absolute windows (seconds since 1970, end inclusive); a photo in any passes.
    public var dateRanges: [ClosedRange<Double>]
    /// Windows in any year ("June", "Christmas").
    public var anyYearWindows: [DayWindow]
    public var placeSpans: [PlaceSpan]
    /// The words that were removed (dates, places, their connectors), folded.
    public var removedWords: [String]
    /// The semantic words that make a query "only a date or place" (`isFilterOnly`).
    public var generalWords: Set<String>

    /// Every place match, span by span.
    public var places: [PlaceMatch] { placeSpans.flatMap(\.matches) }
    public var hasDateFilter: Bool { !dateRanges.isEmpty || !anyYearWindows.isEmpty }
    public var hasPlaceFilter: Bool { !placeSpans.isEmpty }
    public var hasFilter: Bool { hasDateFilter || hasPlaceFilter }

    /// Nothing left to embed but stopwords, "photos" and general trip words, and a date or place to filter by.
    public var isFilterOnly: Bool {
      hasFilter && SearchTerms.terms(semanticText).allSatisfy {
        QueryUnderstanding.emptyWords.contains($0) || generalWords.contains($0)
      }
    }

    /// Whether `created` (seconds since 1970) passes the date filter; always true without one.
    public func matchesDate(_ created: Double?, calendar: Calendar) -> Bool {
      guard hasDateFilter else { return true }
      guard let created else { return false }
      if dateRanges.contains(where: { $0.contains(created) }) { return true }
      guard !anyYearWindows.isEmpty else { return false }
      let year = calendar.component(.year, from: Date(timeIntervalSince1970: created))
      return anyYearWindows.contains { window in
        window.interval(year: year, calendar: calendar).contains(created)
          || window.interval(year: year - 1, calendar: calendar).contains(created)
      }
    }

    /// Whether the coordinate passes the place filter; always true without one, never for a photo without location.
    public func matchesPlace(latitude: Double?, longitude: Double?, locator: PlaceLocator?) -> Bool {
      guard hasPlaceFilter else { return true }
      guard let latitude, let longitude, let locator else { return false }
      let clauses = Dictionary(grouping: placeSpans, by: \.clause)
      return clauses.values.contains { spans in
        spans.allSatisfy { locator.containsAny($0.matches, latitude: latitude, longitude: longitude) }
      }
    }
  }

  /// Folded words that never carry meaning for the embedding when they are all that's left: `SearchTerms`' stopwords
  /// minus the kind words that do ("screenshots", "videos").
  static let emptyWords: Set<String> = SearchTerms.stopwords.subtracting([
    "screenshot", "screenshots", "video", "videos", "clip", "clips", "captura", "capturas",
  ])

  /// Words that keep a query "only a date or place" (they stay in `semanticText`).
  public static let defaultGeneralWords: Set<String> = [
    "trip", "trips", "vacation", "vacations", "holiday", "holidays", "travel", "travels", "visit", "visiting",
    "journey", "getaway", "weekend", "viaje", "viajes", "vacaciones", "paseo", "visita", "everything", "todo", "todas",
    "todos",
  ]

  /// The day of November that is the 4th Thursday.
  static func thanksgivingDay(year: Int, calendar: Calendar) -> Int {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    guard let first = gregorian.date(from: DateComponents(year: year, month: 11, day: 1)) else { return 22 }
    let weekday = gregorian.component(.weekday, from: first)  // 1 = Sunday, 5 = Thursday
    return 1 + (5 - weekday + 7) % 7 + 21
  }

  /// Gregorian Easter Sunday (Meeus/Jones/Butcher).
  static func easter(year y: Int) -> (month: Int, day: Int) {
    let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
    let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
    let m = (a + 11 * h + 22 * l) / 451
    return ((h + l - 7 * m + 114) / 31, (h + l - 7 * m + 114) % 31 + 1)
  }
}
