import Foundation
import Places

extension QueryUnderstanding {
  /// Small words removed with the place that follows them ("trip **to** Puerto Rico", "beach **in** Paris").
  static let placeConnectors: Set<String> = ["in", "to", "at", "from", "near", "around", "of", "en", "a", "al", "de",
                                             "desde", "cerca", "por"]
  /// Words between two places that make them alternatives.
  static let conjunctions: Set<String> = ["and", "or", "y", "o", "e", "u"]

  /// Reads `text` (see the type's notes). `gazetteer` nil: no places. Places found here still need
  /// `Understanding.resolvingPlaces` against the library before they filter.
  public static func parse(_ text: String, now: Date, calendar: Calendar, gazetteer: Gazetteer?,
                           options: Options = Options()) -> Understanding {
    var tokens = tokenize(text)
    let folded = tokens.map(\.folded)
    let nowYear = calendar.component(.year, from: now)

    // Dates.
    let found = dateExpressions(folded, nowYear: nowYear, options: options)
    var holidayTokens = Set<Int>()
    for (range, expr) in found {
      for i in range { tokens[i].role = .date }
      if case .periodic(.holiday, _) = expr { holidayTokens.formUnion(range) }
      markConnectors(&tokens, before: range.lowerBound, from: dateConnectors, owner: nil)
    }
    let filters = dateFilters(found.map(\.1), now: now, calendar: calendar, options: options)
    if options.keepHolidayWords {
      for i in holidayTokens { tokens[i].role = .semantic }
    }

    // Places, in runs of words still semantic.
    var spans: [PlaceSpan] = []
    if let gazetteer {
      var start = 0
      while start < tokens.count {
        guard tokens[start].role == .semantic else { start += 1; continue }
        var end = start
        while end < tokens.count, tokens[end].role == .semantic { end += 1 }
        let run = Array(start..<end)
        let matches = gazetteer.match(run.map { tokens[$0].text })
        for (terms, group) in Dictionary(grouping: matches, by: \.terms).sorted(by: { $0.key.lowerBound < $1.key.lowerBound }) {
          let index = spans.count
          let words = terms.map { tokens[run[$0]].folded }
          spans.append(PlaceSpan(matches: group, clause: 0, words: words))
          for t in terms { tokens[run[t]].role = .place(index) }
          markConnectors(&tokens, before: run[terms.lowerBound], from: placeConnectors, owner: index)
        }
        start = end
      }
      assignClauses(&spans, tokens: &tokens)
    }

    return Understanding(text: text, tokens: tokens, semanticText: "", dateRanges: filters.ranges.map(closed),
                         anyYearWindows: filters.windows, placeSpans: spans, removedWords: [],
                         generalWords: defaultGeneralWords).refreshed()
  }

  static func closed(_ r: Range<Double>) -> ClosedRange<Double> { r.lowerBound...(r.upperBound - 0.001) }

  /// Words: runs of letters, digits and apostrophes; each keeps its typed form and its folded one.
  static func tokenize(_ text: String) -> [Token] {
    var out: [Token] = []
    var current = ""
    func flush() {
      let folded = Gazetteer.fold(current)
      if !folded.isEmpty { out.append(Token(text: current, folded: folded, role: .semantic)) }
      current = ""
    }
    for ch in text {
      if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" { current.append(ch) } else { flush() }
    }
    flush()
    return out
  }

  /// Up to two semantic words right before `index` that are in `words` become connectors of `owner`.
  static func markConnectors(_ tokens: inout [Token], before index: Int, from words: Set<String>, owner: Int?) {
    var i = index - 1
    var marked = 0
    while i >= 0, marked < 2, tokens[i].role == .semantic, words.contains(tokens[i].folded) {
      tokens[i].role = .connector(owner)
      i -= 1
      marked += 1
    }
  }

  /// Consecutive spans share a clause unless a conjunction sits between them (then it is removed with the later span).
  static func assignClauses(_ spans: inout [PlaceSpan], tokens: inout [Token]) {
    guard spans.count > 1 else { return }
    func range(_ span: Int) -> ClosedRange<Int>? {
      let at = tokens.indices.filter { tokens[$0].role == .place(span) }
      guard let a = at.first, let b = at.last else { return nil }
      return a...b
    }
    var clause = 0
    for s in 1..<spans.count {
      guard let previous = range(s - 1), let this = range(s) else { continue }
      let between = (previous.upperBound + 1)..<this.lowerBound
      if let c = between.first(where: { conjunctions.contains(tokens[$0].folded) }) {
        clause += 1
        for i in between where tokens[i].role == .semantic && conjunctions.contains(tokens[i].folded) || i == c {
          tokens[i].role = .connector(s)
        }
      }
      spans[s].clause = clause
    }
  }
}

extension QueryUnderstanding.Understanding {
  /// Recomputes `semanticText` and `removedWords` from the tokens' roles.
  func refreshed() -> Self {
    var copy = self
    copy.semanticText = tokens.filter { $0.role == .semantic }.map(\.text).joined(separator: " ")
    copy.removedWords = tokens.filter { $0.role != .semantic }.map(\.folded)
    return copy
  }

  /// Keeps only the place matches that hold at least `minimumPhotos` of `locations` (the library's located photos);
  /// a span left with none gives its words (and connectors) back to `semanticText`. A place nobody photographed is
  /// more likely a word ("wedding", "paradise", "jordan") than a filter that would empty the answer.
  public func resolvingPlaces(locations: [(latitude: Double, longitude: Double)], locator: PlaceLocator,
                              minimumPhotos: Int) -> Self {
    guard hasPlaceFilter else { return self }
    var copy = self
    var keptIndex: [Int: Int] = [:]
    var spans: [QueryUnderstanding.PlaceSpan] = []
    for (i, span) in placeSpans.enumerated() {
      let kept = span.matches.filter { match in
        guard minimumPhotos > 0 else { return true }
        var n = 0
        for location in locations where locator.contains(match, latitude: location.latitude,
                                                         longitude: location.longitude) {
          n += 1
          if n >= minimumPhotos { return true }
        }
        return false
      }
      guard !kept.isEmpty else { continue }
      keptIndex[i] = spans.count
      var s = span
      s.matches = kept
      spans.append(s)
    }
    for t in copy.tokens.indices {
      switch copy.tokens[t].role {
      case .place(let i): copy.tokens[t].role = keptIndex[i].map { .place($0) } ?? .semantic
      case .connector(let i?): copy.tokens[t].role = keptIndex[i].map { .connector($0) } ?? .semantic
      default: break
      }
    }
    // Clauses renumbered in order.
    var clauseMap: [Int: Int] = [:]
    for s in spans.indices {
      let c = spans[s].clause
      if clauseMap[c] == nil { clauseMap[c] = clauseMap.count }
      spans[s].clause = clauseMap[c]!
    }
    copy.placeSpans = spans
    return copy.refreshed()
  }
}
