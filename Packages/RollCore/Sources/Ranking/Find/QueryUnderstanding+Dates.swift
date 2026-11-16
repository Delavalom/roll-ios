import Foundation
import Places

// The date words: lexicon, matching and the windows they mean.
extension QueryUnderstanding {
  enum Season: Sendable { case spring, summer, fall, winter }

  enum Holiday: Sendable {
    case christmasEve, christmas, newYearsEve, newYearsDay, newYear, halloween, thanksgiving, julyFourth, valentines, easter

    var window: DayWindow {
      switch self {
      case .christmasEve: .days(startMonth: 12, startDay: 24, endMonth: 12, endDay: 25)
      case .christmas: .days(startMonth: 12, startDay: 24, endMonth: 12, endDay: 27)
      // The night runs into the small hours of 1 January.
      case .newYearsEve: .days(startMonth: 12, startDay: 31, endMonth: 1, endDay: 2)
      case .newYearsDay: .days(startMonth: 1, startDay: 1, endMonth: 1, endDay: 2)
      case .newYear: .days(startMonth: 12, startDay: 31, endMonth: 1, endDay: 2)
      // Parties and trick-or-treat photos often land after midnight.
      case .halloween: .days(startMonth: 10, startDay: 31, endMonth: 11, endDay: 2)
      case .thanksgiving: .thanksgiving
      case .julyFourth: .days(startMonth: 7, startDay: 4, endMonth: 7, endDay: 6)
      case .valentines: .days(startMonth: 2, startDay: 14, endMonth: 2, endDay: 15)
      case .easter: .easter
      }
    }
  }

  enum Periodic: Sendable {
    case month(Int)
    case season(Season)
    case holiday(Holiday)
  }

  enum Qualifier: Sendable { case last, this }

  enum DateExpr: Sendable {
    case year(Int)
    /// "this year" (0), "last year" (-1).
    case relativeYear(Int)
    case today, yesterday, lastWeek, thisWeek, lastMonth, thisMonth
    case periodic(Periodic, Qualifier?)
  }

  static let months: [String: Int] = [
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
    "jan": 1, "feb": 2, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6, "julio": 7, "agosto": 8,
    "septiembre": 9, "setiembre": 9, "octubre": 10, "noviembre": 11, "diciembre": 12,
  ]
  /// Month names that are also everyday words ("may", "march", "mayo"): dates only with a hint.
  static let ambiguousMonths: Set<String> = ["may", "march", "mayo"]

  static let seasons: [String: Season] = [
    "summer": .summer, "verano": .summer, "winter": .winter, "invierno": .winter, "spring": .spring,
    "primavera": .spring, "fall": .fall, "autumn": .fall, "otono": .fall,
  ]

  /// Longest phrases first at each position.
  static let holidays: [([String], Holiday)] = [
    (["dia", "de", "accion", "de", "gracias"], .thanksgiving), (["dia", "de", "san", "valentin"], .valentines),
    (["dia", "de", "los", "enamorados"], .valentines), (["dia", "de", "ano", "nuevo"], .newYearsDay),
    (["new", "years", "eve"], .newYearsEve), (["new", "year", "eve"], .newYearsEve), (["new", "years", "day"], .newYearsDay),
    (["new", "year", "day"], .newYearsDay), (["fourth", "of", "july"], .julyFourth), (["4th", "of", "july"], .julyFourth),
    (["4", "de", "julio"], .julyFourth), (["cuatro", "de", "julio"], .julyFourth), (["accion", "de", "gracias"], .thanksgiving),
    (["fin", "de", "ano"], .newYearsEve), (["christmas", "eve"], .christmasEve), (["xmas", "eve"], .christmasEve),
    (["noche", "buena"], .christmasEve), (["noche", "vieja"], .newYearsEve), (["christmas", "day"], .christmas),
    (["new", "years"], .newYear), (["new", "year"], .newYear), (["ano", "nuevo"], .newYear), (["july", "4th"], .julyFourth),
    (["july", "4"], .julyFourth), (["independence", "day"], .julyFourth), (["valentines", "day"], .valentines),
    (["valentine", "day"], .valentines), (["san", "valentin"], .valentines), (["easter", "sunday"], .easter),
    (["semana", "santa"], .easter), (["christmas"], .christmas), (["xmas"], .christmas), (["navidad"], .christmas),
    (["navidades"], .christmas), (["nochebuena"], .christmasEve), (["nochevieja"], .newYearsEve), (["nye"], .newYearsEve),
    (["halloween"], .halloween), (["thanksgiving"], .thanksgiving), (["valentines"], .valentines),
    (["valentine"], .valentines), (["easter"], .easter), (["pascua"], .easter),
  ]

  static let relatives: [([String], DateExpr)] = [
    (["el", "ano", "pasado"], .relativeYear(-1)), (["la", "semana", "pasada"], .lastWeek),
    (["el", "mes", "pasado"], .lastMonth), (["ano", "pasado"], .relativeYear(-1)), (["semana", "pasada"], .lastWeek),
    (["mes", "pasado"], .lastMonth), (["last", "year"], .relativeYear(-1)), (["past", "year"], .relativeYear(-1)),
    (["this", "year"], .relativeYear(0)), (["este", "ano"], .relativeYear(0)), (["last", "week"], .lastWeek),
    (["past", "week"], .lastWeek), (["this", "week"], .thisWeek), (["esta", "semana"], .thisWeek),
    (["last", "month"], .lastMonth), (["past", "month"], .lastMonth), (["this", "month"], .thisMonth),
    (["este", "mes"], .thisMonth), (["yesterday"], .yesterday), (["ayer"], .yesterday), (["today"], .today),
    (["hoy"], .today),
  ]

  static let lastWords: Set<String> = ["last", "past", "previous"]
  static let thisWords: Set<String> = ["this", "este", "esta"]
  static let pastSuffix: Set<String> = ["pasado", "pasada"]
  /// Words before an ambiguous month or bare season that make it a date ("in may", "en mayo", "during summer").
  static let dateHints: Set<String> = ["in", "en", "during", "durante", "since", "desde"]
  /// Small words removed with the date or place that follows them.
  static let dateConnectors: Set<String> = [
    "in", "on", "at", "during", "from", "of", "since", "around", "en", "de", "del", "durante", "desde", "el", "la", "for",
  ]

  /// The date expressions in `folded`, with the token ranges they cover.
  static func dateExpressions(_ folded: [String], nowYear: Int, options: Options) -> [(Range<Int>, DateExpr)] {
    func isYear(_ i: Int) -> Int? {
      guard i >= 0, i < folded.count, folded[i].count == 4, let y = Int(folded[i]),
            y >= options.minYear, y <= nowYear + options.maxYearsAhead else { return nil }
      return y
    }
    func phrase(_ words: [String], at i: Int) -> Bool {
      i + words.count <= folded.count && Array(folded[i..<(i + words.count)]) == words
    }
    /// A month, season or holiday at `i`: its length and value; `hinted` when a year, qualifier or hint makes it
    /// a date whatever the word.
    func periodic(at i: Int) -> (Int, Periodic, ambiguous: Bool)? {
      for (words, holiday) in holidays where phrase(words, at: i) { return (words.count, .holiday(holiday), false) }
      guard i < folded.count else { return nil }
      if let m = months[folded[i]] { return (1, .month(m), ambiguousMonths.contains(folded[i])) }
      if let s = seasons[folded[i]] { return (1, .season(s), !options.bareSeasonIsDate) }
      return nil
    }

    var out: [(Range<Int>, DateExpr)] = []
    var i = 0
    while i < folded.count {
      if let (words, expr) = relatives.first(where: { phrase($0.0, at: i) }) {
        out.append((i..<(i + words.count), expr))
        i += words.count
        continue
      }
      // "last summer", "this christmas"
      if lastWords.contains(folded[i]) || thisWords.contains(folded[i]), let (n, p, _) = periodic(at: i + 1) {
        let q: Qualifier = lastWords.contains(folded[i]) ? .last : .this
        out.append((i..<(i + 1 + n), .periodic(p, q)))
        i += 1 + n
        continue
      }
      // "el verano pasado", "la navidad pasada", "verano pasado"
      let article = (folded[i] == "el" || folded[i] == "la") ? 1 : 0
      if let (n, p, _) = periodic(at: i + article), i + article + n < folded.count,
         pastSuffix.contains(folded[i + article + n]) {
        out.append((i..<(i + article + n + 1), .periodic(p, .last)))
        i += article + n + 1
        continue
      }
      if let (n, p, ambiguous) = periodic(at: i) {
        // "june 2024", "junio de 2023", "summer of 2022"
        var yearAt: Int? = nil
        if isYear(i + n) != nil {
          yearAt = i + n
        } else if i + n < folded.count, ["de", "of", "del"].contains(folded[i + n]), isYear(i + n + 1) != nil {
          yearAt = i + n + 1
        }
        let hinted = yearAt != nil || isYear(i - 1) != nil || (i > 0 && dateHints.contains(folded[i - 1]))
        if !ambiguous || hinted {
          out.append((i..<(i + n), .periodic(p, nil)))
          if let yearAt, let y = isYear(yearAt) {
            out.append(((i + n)..<(yearAt + 1), .year(y)))
            i = yearAt + 1
          } else {
            i += n
          }
          continue
        }
      }
      if let y = isYear(i) {
        out.append((i..<(i + 1), .year(y)))
      }
      i += 1
    }
    return out
  }

  /// Absolute ranges and any-year windows for the expressions found.
  static func dateFilters(_ exprs: [DateExpr], now: Date, calendar: Calendar, options: Options)
    -> (ranges: [Range<Double>], windows: [DayWindow]) {
    let t = now.timeIntervalSince1970
    let nowYear = calendar.component(.year, from: now)
    func yearRange(_ y: Int) -> Range<Double> { DayWindow.days(startMonth: 1, startDay: 1, endMonth: 1, endDay: 1)
      .interval(year: y, calendar: calendar) }
    func unit(_ component: Calendar.Component, _ date: Date) -> Range<Double> {
      guard let i = calendar.dateInterval(of: component, for: date) else { return t..<t }
      return i.start.timeIntervalSince1970..<i.end.timeIntervalSince1970
    }
    func window(_ p: Periodic) -> DayWindow {
      switch p {
      case .month(let m): return .month(m)
      case .holiday(let h): return h.window
      case .season(let s):
        let south = options.southernHemisphere
        switch (s, south) {
        case (.spring, false), (.fall, true): return .days(startMonth: 3, startDay: 1, endMonth: 6, endDay: 1)
        case (.summer, false), (.winter, true): return .days(startMonth: 6, startDay: 1, endMonth: 9, endDay: 1)
        case (.fall, false), (.spring, true): return .days(startMonth: 9, startDay: 1, endMonth: 12, endDay: 1)
        case (.winter, false), (.summer, true): return .days(startMonth: 12, startDay: 1, endMonth: 3, endDay: 1)
        }
      }
    }
    /// The windows of `p` that belong to calendar year `y`. A season that wraps (winter) is its two halves in that
    /// year; a holiday that wraps (New Year's Eve) is the one that starts in it.
    func inYear(_ p: Periodic, _ y: Int) -> [Range<Double>] {
      let w = window(p)
      let starting = w.interval(year: y, calendar: calendar)
      guard case .season = p, starting.upperBound > yearRange(y).upperBound else { return [starting] }
      let year = yearRange(y)
      let before = w.interval(year: y - 1, calendar: calendar)
      return [year.lowerBound..<min(before.upperBound, year.upperBound), starting.lowerBound..<year.upperBound]
    }

    var years: [Int] = []
    var periodicFree: [Periodic] = []
    var ranges: [Range<Double>] = []
    let today = calendar.startOfDay(for: now)
    for expr in exprs {
      switch expr {
      case .year(let y): years.append(y)
      case .relativeYear(let offset): years.append(nowYear + offset)
      case .today: ranges.append(unit(.day, now))
      case .yesterday: ranges.append(unit(.day, today.addingTimeInterval(-3_600)))
      case .thisWeek: ranges.append(unit(.weekOfYear, now))
      case .lastWeek: ranges.append(unit(.weekOfYear, Date(timeIntervalSince1970: unit(.weekOfYear, now).lowerBound - 3_600)))
      case .thisMonth: ranges.append(unit(.month, now))
      case .lastMonth: ranges.append(unit(.month, Date(timeIntervalSince1970: unit(.month, now).lowerBound - 3_600)))
      case .periodic(let p, nil): periodicFree.append(p)
      case .periodic(let p, .last?):
        let w = window(p)
        if let k = (nowYear - 2...nowYear).reversed().first(where: { w.interval(year: $0, calendar: calendar).upperBound <= t }) {
          ranges.append(w.interval(year: k, calendar: calendar))
        }
      case .periodic(let p, .this?):
        let w = window(p)
        let current = [nowYear - 1, nowYear].map { w.interval(year: $0, calendar: calendar) }.first { $0.contains(t) }
        ranges.append(current ?? w.interval(year: nowYear, calendar: calendar))
      }
    }
    var windows: [DayWindow] = []
    if years.isEmpty {
      windows = periodicFree.map(window)
    } else if periodicFree.isEmpty {
      ranges += years.map(yearRange)
    } else {
      for y in years { for p in periodicFree { ranges += inYear(p, y) } }
    }
    return (ranges.filter { !$0.isEmpty }, windows)
  }
}
