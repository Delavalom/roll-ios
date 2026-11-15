import Foundation
import Places
import Store

/// What an Ask Roll answer shows, built only from a `FindSearch.Result` (ADR-0005: every sentence comes from data).
/// Pure, so the app's views only lay it out:
///
/// - **Sections** when the answer is grouped by event (place name if the event has one, its dates, how many photos;
///   best section first, as `FindSearch` ordered them), else one flat grid of `strong`.
/// - **Weaker** matches stay folded ("N more possible matches").
/// - **Nothing found**: the query was refused (`FindConfig.nothingFound`); `closest` holds at most `closestLimit` of
///   the best photos from the same search without the refusal, shown as "Closest results", never as matches.
/// - **Notes** for photos a filter couldn't test ("12 photos have no location…").
public struct FindAnswer: Sendable, Equatable {
  public struct Section: Sendable, Equatable, Identifiable {
    /// The event id; "" for the photos in no event.
    public var id: String
    public var eventId: String?
    /// "Lisbon", from the event's nearest place; nil when it has none.
    public var place: String?
    /// "Jun 3–7, 2024"; nil when nothing in it has a date.
    public var dates: String?
    /// The matches, in the answer's order.
    public var ids: [String]
    /// The event's other photos, in time order ("rest of this day").
    public var rest: [String]
    /// "day", "trip" or "event": what `rest` is the rest of.
    public var restNoun: String

    /// "Lisbon · Jun 3–7, 2024", "Jun 3–7, 2024", or "Other matches".
    public var title: String {
      let parts = [place, dates].compactMap { $0 }
      return parts.isEmpty ? "Other matches" : parts.joined(separator: " · ")
    }

    /// "8 photos".
    public var countText: String { FindAnswer.photos(ids.count) }

    /// "+ 46 more from this day", or nil when there's no rest.
    public var restText: String? {
      rest.isEmpty ? nil : "+ \(rest.count.formatted()) more from this \(restNoun)"
    }

    /// The album name a section suggests: its place and dates ("Lisbon, Jun 3–7, 2024").
    public var albumName: String {
      let parts = [place, dates].compactMap { $0 }
      return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }
  }

  public static let closestLimit = 12

  /// Event sections (empty: show `strong` as one grid).
  public var sections: [Section] = []
  public var strong: [String] = []
  public var weaker: [String] = []
  public var nothingFound = false
  /// Only with `nothingFound`.
  public var closest: [String] = []
  public var notes: [String] = []

  public init() {}

  /// - Parameters:
  ///   - closest: the same query searched without the refusal (`FindConfig.withoutNothingFound`), used only when
  ///     `result.nothingFound`.
  public init(result: FindSearch.Result, closest: FindSearch.Result? = nil, calendar: Calendar = .current,
              locale: Locale = .current) {
    strong = result.matches.map(\.id)
    weaker = result.weaker.map(\.id)
    nothingFound = result.nothingFound
    if nothingFound, let closest {
      self.closest = Array((closest.matches + closest.weaker).prefix(Self.closestLimit).map(\.id))
    }
    if result.sections.contains(where: { $0.eventId != nil }) {
      sections = result.sections.map { Self.section($0, calendar: calendar, locale: locale) }
    }
    notes = Self.notes(result)
  }

  public var isEmpty: Bool { strong.isEmpty && closest.isEmpty }

  /// "N more possible matches", or nil when none are folded.
  public var weakerText: String? {
    weaker.isEmpty ? nil : "\(weaker.count.formatted()) more possible \(weaker.count == 1 ? "match" : "matches")"
  }

  // MARK: - Pieces

  static func section(_ s: FindSearch.Section, calendar: Calendar, locale: Locale) -> Section {
    let created = s.matches.compactMap(\.created)
    let start = s.event?.startAt ?? created.min()
    let end = s.event?.endAt ?? created.max()
    let dates = start.flatMap { start in end.map { dateRange(start: start, end: $0, calendar: calendar, locale: locale) } }
    let noun: String
    if s.event?.kind == .trip {
      noun = "trip"
    } else if let start, let end, calendar.isDate(Date(timeIntervalSince1970: start),
                                                    inSameDayAs: Date(timeIntervalSince1970: end)) {
      noun = "day"
    } else {
      noun = "event"
    }
    return Section(id: s.id, eventId: s.eventId, place: s.eventId == nil ? nil : placeName(s.event), dates: dates,
                   ids: s.matches.map(\.id), rest: s.rest, restNoun: noun)
  }

  /// The event's city, else its region, else its country.
  static func placeName(_ event: EventRecord?) -> String? {
    for name in [event?.city, event?.admin1, event?.country] {
      if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
    }
    return nil
  }

  /// "Jun 3, 2024", "Jun 3–7, 2024", "Jun 28 – Jul 2, 2024", "Dec 30, 2023 – Jan 2, 2024".
  public static func dateRange(start: Double, end: Double, calendar: Calendar, locale: Locale) -> String {
    let a = Date(timeIntervalSince1970: min(start, end)), b = Date(timeIntervalSince1970: max(start, end))
    func format(_ template: String, _ date: Date) -> String {
      let f = DateFormatter()
      f.calendar = calendar
      f.timeZone = calendar.timeZone
      f.locale = locale
      f.setLocalizedDateFormatFromTemplate(template)
      return f.string(from: date)
    }
    let ya = calendar.component(.year, from: a), yb = calendar.component(.year, from: b)
    if calendar.isDate(a, inSameDayAs: b) { return "\(format("MMMd", a)), \(ya)" }
    if ya == yb, calendar.component(.month, from: a) == calendar.component(.month, from: b) {
      return "\(format("MMMd", a))–\(calendar.component(.day, from: b)), \(ya)"
    }
    if ya == yb { return "\(format("MMMd", a)) – \(format("MMMd", b)), \(ya)" }
    return "\(format("MMMd", a)), \(ya) – \(format("MMMd", b)), \(yb)"
  }

  /// Photos a filter couldn't test, as counted by the search.
  static func notes(_ r: FindSearch.Result) -> [String] {
    var out: [String] = []
    let place = r.understanding?.places.first?.name
    if r.missingLocation > 0 {
      let have = r.missingLocation == 1 ? "photo has" : "photos have"
      out.append("\(r.missingLocation.formatted()) \(have) no location, so Roll couldn't tell if "
                 + (r.missingLocation == 1 ? "it's" : "they're") + " from \(place ?? "there")."
                 + " \(r.missingLocation == 1 ? "It's" : "They're") left out.")
    }
    if r.missingDate > 0 {
      let have = r.missingDate == 1 ? "photo has" : "photos have"
      out.append("\(r.missingDate.formatted()) \(have) no date, so \(r.missingDate == 1 ? "it's" : "they're") left out.")
    }
    if r.locationUnchecked > 0 {
      out.append("Roll hasn't read where \(photos(r.locationUnchecked)) were taken yet. "
                 + "\(r.locationUnchecked == 1 ? "It's" : "They're") left out until it has.")
    }
    return out
  }

  static func photos(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "photo" : "photos")" }
}
