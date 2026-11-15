import Foundation
@testable import Ranking
import Store
import Testing

private var utc: Calendar {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "UTC")!
  return c
}

private let us = Locale(identifier: "en_US")

/// Seconds since 1970 for a UTC date.
private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Double {
  utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970
}

private func match(_ id: String, created: Double? = nil, event: String? = nil, score: Float = 1) -> FindSearch.Match {
  FindSearch.Match(asset: SearchAsset(id: id, mediaType: 1, estBytes: 1, created: created, isFavorite: false,
                                      originalLocal: nil),
                   score: score, z: 3, coverage: 0, tagCoverage: 0, bonus: 0, eventId: event)
}

struct FindAnswerTests {
  @Test func showsEventSectionsWithPlaceDatesAndCountBestFirst() {
    var r = FindSearch.Result()
    r.matches = [match("a", event: "trip"), match("b", event: "trip"), match("c", created: at(2024, 3, 2), event: "m")]
    let trip = EventRecord(id: "trip", kind: .trip, startAt: at(2024, 6, 3), endAt: at(2024, 6, 7), count: 40,
                           city: "Lisbon", country: "Portugal")
    let moment = EventRecord(id: "m", kind: .moment, startAt: at(2024, 3, 2, 9), endAt: at(2024, 3, 2, 17), count: 9)
    r.sections = [FindSearch.Section(eventId: "trip", event: trip, matches: Array(r.matches.prefix(2)), score: 2,
                                     rest: ["x", "y"]),
                  FindSearch.Section(eventId: "m", event: moment, matches: [r.matches[2]], score: 1)]
    let a = FindAnswer(result: r, calendar: utc, locale: us)
    #expect(a.sections.map(\.title) == ["Lisbon · Jun 3–7, 2024", "Mar 2, 2024"])
    #expect(a.sections.map(\.countText) == ["2 photos", "1 photo"])
    #expect(a.sections[0].restText == "+ 2 more from this trip")
    #expect(a.sections[1].restText == nil)
    #expect(a.sections[1].restNoun == "day")
    #expect(a.sections[0].albumName == "Lisbon, Jun 3–7, 2024")
    #expect(a.strong == ["a", "b", "c"])
  }

  @Test func photosInNoEventAloneMakeAFlatGrid() {
    var r = FindSearch.Result()
    r.matches = [match("a"), match("b")]
    r.weaker = [match("w")]
    r.sections = [FindSearch.Section(eventId: nil, event: nil, matches: r.matches, score: 1)]
    let a = FindAnswer(result: r)
    #expect(a.sections.isEmpty)
    #expect(a.strong == ["a", "b"])
    #expect(a.weakerText == "1 more possible match")
    #expect(FindAnswer(result: FindSearch.Result()).weakerText == nil)
  }

  @Test func aLooseSectionIsTitledOtherMatches() {
    var r = FindSearch.Result()
    r.matches = [match("a", event: "m"), match("b")]
    r.sections = [FindSearch.Section(eventId: "m", event: nil, matches: [r.matches[0]], score: 1),
                  FindSearch.Section(eventId: nil, event: nil, matches: [r.matches[1]], score: 1)]
    let a = FindAnswer(result: r, calendar: utc, locale: us)
    #expect(a.sections.map(\.title) == ["Other matches", "Other matches"])
    #expect(a.sections[0].albumName == "")
  }

  @Test func nothingFoundShowsAtMostTwelveClosestAndNoMatches() {
    var refused = FindSearch.Result()
    refused.nothingFound = true
    var open = FindSearch.Result()
    open.matches = (0..<10).map { match("m\($0)") }
    open.weaker = (0..<5).map { match("w\($0)") }
    let a = FindAnswer(result: refused, closest: open)
    #expect(a.nothingFound)
    #expect(a.strong.isEmpty)
    #expect(a.closest == (0..<10).map { "m\($0)" } + ["w0", "w1"])
    #expect(!a.isEmpty)
    // A query that wasn't refused never has closest results.
    #expect(FindAnswer(result: open, closest: open).closest.isEmpty)
  }

  @Test func notesComeFromTheCounts() {
    var r = FindSearch.Result()
    r.missingLocation = 12
    r.missingDate = 1
    r.locationUnchecked = 240
    let a = FindAnswer(result: r)
    #expect(a.notes == [
      "12 photos have no location, so Roll couldn't tell if they're from there. They're left out.",
      "1 photo has no date, so it's left out.",
      "Roll hasn't read where 240 photos were taken yet. They're left out until it has.",
    ])
    #expect(FindAnswer(result: FindSearch.Result()).notes.isEmpty)
  }

  @Test func dateRanges() {
    func range(_ a: Double, _ b: Double) -> String { FindAnswer.dateRange(start: a, end: b, calendar: utc, locale: us) }
    #expect(range(at(2024, 6, 3, 8), at(2024, 6, 3, 20)) == "Jun 3, 2024")
    #expect(range(at(2024, 6, 3), at(2024, 6, 7)) == "Jun 3–7, 2024")
    #expect(range(at(2024, 6, 28), at(2024, 7, 2)) == "Jun 28 – Jul 2, 2024")
    #expect(range(at(2023, 12, 30), at(2024, 1, 2)) == "Dec 30, 2023 – Jan 2, 2024")
    #expect(range(at(2024, 6, 7), at(2024, 6, 3)) == "Jun 3–7, 2024", "order doesn't matter")
  }

  @Test func shippingIsV0WithTheCutRefusalEventsAndUnderstanding() {
    let s = FindConfig.shipping
    #expect(s.relativeCut == 0.6)
    #expect(s.nothingFound == NothingFoundTest(minTopCosine: 0.735))
    #expect(s.understanding && s.events && s.groupByEvent && s.expandRest)
    #expect(s.zGate == FindConfig.v0.zGate && s.foldRatio == FindConfig.v0.foldRatio && s.templates.isEmpty)
    #expect(FindConfig.default == FindConfig.v0, "the engine's default is unchanged")
    #expect(s.withoutNothingFound.nothingFound.isOff)
    #expect(s.withoutNothingFound.relativeCut == 0.6)
  }
}
