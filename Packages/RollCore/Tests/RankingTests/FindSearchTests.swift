import Foundation
import Places
@testable import Ranking
import Store
import Testing

private let utc: Calendar = {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "UTC")!
  return c
}()
private func day(_ y: Int, _ m: Int, _ d: Int) -> Double {
  utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!.timeIntervalSince1970
}
private let now = day(2026, 11, 15)
/// Mean 0, deviation 0.1: a cosine of `z / 10` has that z.
private let scale = QueryScale(scores: Array(repeating: -0.1, count: 50) + Array(repeating: 0.1, count: 50))

private func asset(_ id: String, created: Double? = day(2024, 6, 1), bytes: Int64 = 100, favorite: Bool = false,
                   local: Bool? = true) -> SearchAsset {
  SearchAsset(id: id, mediaType: 1, estBytes: bytes, created: created, isFavorite: favorite, originalLocal: local)
}
private func cand(_ id: String, z: Float?, words: Double = 0, tags: Double = 0, created: Double? = day(2024, 6, 1),
                  at: (Double, Double)? = nil, event: String? = nil, trip: String? = nil, seedZ: Float? = nil)
  -> FindSearch.Candidate {
  FindSearch.Candidate(asset: asset(id, created: created), cosines: z.map { [$0 / 10] } ?? [],
                       seedCosine: seedZ.map { $0 / 10 }, coverage: words, tagCoverage: tags, latitude: at?.0,
                       longitude: at?.1, eventId: event, tripId: trip)
}
private func context(_ u: QueryUnderstanding.Understanding? = nil, locator: PlaceLocator? = nil,
                     scales: [QueryScale] = [scale], seed: Bool = false, topZ: [Float]? = nil,
                     refinement: PhotoSearch.Refinement = .init()) -> FindSearch.Context {
  FindSearch.Context(scales: scales, seedScale: seed ? scale : nil, understanding: u, locator: locator, compared: 1_000,
                     topZ: topZ, calendar: utc, now: now, refinement: refinement)
}
private func ids(_ r: FindSearch.Result) -> [String] { r.matches.map(\.id) }

struct FindSearchV0Tests {
  @Test func v0IsTodaysPhotoSearchExactly() {
    var rng = SeededRNG(seed: 5)
    for trial in 0..<12 {
      let n = 300
      var cosines: [Float] = []
      var candidates: [FindSearch.Candidate] = []
      for i in 0..<n {
        let c = i % 11 == 0 ? Float.random(in: 0.85...1, using: &rng) : Float.random(in: 0.2...0.7, using: &rng)
        cosines.append(c)
        let words = i % 17 == 0 ? Double.random(in: 0...1, using: &rng) : 0
        let a = asset(String(format: "a%03d", i), created: i % 9 == 0 ? nil : now - Double(i) * 86_400 * 3,
                      bytes: Int64.random(in: 1...50, using: &rng), favorite: i % 5 == 0,
                      local: i % 4 == 0 ? nil : i % 3 == 0)
        candidates.append(FindSearch.Candidate(asset: a, cosines: [c], coverage: words))
      }
      let library = QueryScale(scores: cosines)
      let refinement = PhotoSearch.Refinement(olderThanAYear: trial % 2 == 1, biggestFirst: trial % 3 == 1,
                                              onlyOnThisIPhone: trial % 4 == 3)
      let lookup = trial % 5 == 4
      let expected = PhotoSearch.rank(
        candidates.map { PhotoSearch.Scored(asset: $0.asset, score: $0.cosines[0], coverage: $0.coverage) },
        scale: library, compared: 5_000, lookup: lookup, refinement: refinement, now: now)
      let ctx = FindSearch.Context(scales: [library], lookup: lookup, compared: 5_000, now: now,
                                   refinement: refinement)
      let found = FindSearch.rank(candidates, context: ctx, config: .v0)
      #expect(found.photoSearch == expected, "trial \(trial)")
      #expect(!expected.matches.isEmpty)
      #expect(found.sections.isEmpty && !found.nothingFound)
    }
  }

  @Test func cutOffComposes() {
    let cands = (0..<10).map { cand("p\($0)", z: Float(10 - $0)) }  // z 10, 9, … 1
    var config = FindConfig()
    #expect(ids(FindSearch.rank(cands, context: context(), config: config)) == (0..<7).map { "p\($0)" })
    #expect(FindSearch.rank(cands, context: context(), config: config).weaker.map(\.id) == ["p7", "p8"])
    config.zGate = 3
    #expect(ids(FindSearch.rank(cands, context: context(), config: config)).count == 7)
    #expect(FindSearch.rank(cands, context: context(), config: config).weaker.map(\.id) == ["p7"])
    config.relativeCut = 0.7  // keeps z >= 7
    #expect(ids(FindSearch.rank(cands, context: context(), config: config)) == ["p0", "p1", "p2", "p3"])
    config.maxResults = 2
    let capped = FindSearch.rank(cands, context: context(), config: config)
    #expect(ids(capped) == ["p0", "p1"] && capped.weaker.isEmpty)
    config.foldRatio = 0.95
    let folded = FindSearch.rank(cands, context: context(), config: config)
    #expect(ids(folded) == ["p0"] && folded.weaker.map(\.id) == ["p1"])
  }

  @Test func nothingFoundIsAQueryLevelTest() {
    let flat = (0..<60).map { cand("n\($0)", z: 2.5 - Float($0) * 0.001) }
    var config = FindConfig()
    #expect(!FindSearch.rank(flat, context: context(), config: config).nothingFound)  // off by default
    config.nothingFound.minTopZ = 3
    let refused = FindSearch.rank(flat, context: context(), config: config)
    #expect(refused.nothingFound && refused.matches.isEmpty && abs(refused.topZ! - 2.5) < 1e-4)
    // Words rescue a query.
    #expect(!FindSearch.rank(flat + [cand("w", z: 0, words: 1)], context: context(), config: config).nothingFound)
    // A crowd with no head: best minus the 50th is under 0.5.
    config.nothingFound = NothingFoundTest(minTopGap: 0.5)
    #expect(FindSearch.rank(flat, context: context(), config: config).nothingFound)
    let headed = flat + [cand("hit", z: 6)]
    #expect(!FindSearch.rank(headed, context: context(), config: config).nothingFound)
    // The library's own top z (from the engine) wins over the candidates'.
    #expect(FindSearch.rank(headed, context: context(topZ: Array(repeating: 2, count: 60)), config: config).nothingFound)
    // requireAll: refused only when every test fails.
    config.nothingFound = NothingFoundTest(minTopZ: 3, minTopGap: 0.001, requireAll: true)
    #expect(!FindSearch.rank(flat, context: context(), config: config).nothingFound)
    #expect(NothingFoundTest(minTopCosine: 0.5).refuses(topZ: [9], topCosine: 0.4))
    #expect(!NothingFoundTest(minTopGap: 1, gapRank: 50).refuses(topZ: [3, 2], topCosine: nil))  // too few for a crowd
  }
}

struct FindSearchVariantTests {
  @Test func templatesCombineByMaxOrMean() {
    let two = [scale, scale]
    let a = FindSearch.Candidate(asset: asset("a"), cosines: [0.5, 0.0])  // z 5 and 0
    let b = FindSearch.Candidate(asset: asset("b"), cosines: [0.3, 0.3])  // z 3 and 3
    var config = FindConfig.v1
    #expect(ids(FindSearch.rank([a, b], context: context(scales: two), config: config)) == ["a", "b"])
    config.combine = .mean
    #expect(ids(FindSearch.rank([a, b], context: context(scales: two), config: config)) == ["b", "a"])
    #expect(FindQuery.texts(for: " dog ", config: .v1) == ["dog", "a photo of dog"])
    var noBare = FindConfig.v1
    noBare.includeBareQuery = false
    noBare.templates = ["{q}", "pictures of"]
    #expect(FindQuery.texts(for: "dog", config: noBare) == ["dog", "pictures of dog"])
    #expect(FindQuery.texts(for: "  ", config: .v1).isEmpty)
  }

  @Test func datesFilterAndCountWhatHasNoDate() {
    let u = QueryUnderstanding.parse("dog 2024", now: Date(timeIntervalSince1970: now), calendar: utc, gazetteer: nil)
    let cands = [cand("in", z: 1.5), cand("strong", z: 4), cand("old", z: 4, created: day(2023, 6, 1)),
                 cand("undated", z: 4, created: nil), cand("weak", z: 0.5)]
    let off = FindSearch.rank(cands, context: context(u), config: .v0)  // understanding off: V0
    #expect(Set(ids(off)) == ["strong", "old", "undated"])
    let r = FindSearch.rank(cands, context: context(u), config: .v2)
    #expect(Set(ids(r) + r.weaker.map(\.id)) == ["strong", "in"])  // filteredZGate 1 under a filter
    #expect(r.missingDate == 1 && r.missingLocation == 0 && !r.filterOnly)
  }

  @Test func placeOnlyQueriesReturnEverythingThereByTimeInSections() throws {
    let g = try Gazetteer.load()
    let madrid = (40.4165, -3.7026), lisbon = (38.7167, -9.1333)  // public city centres
    let parsed = QueryUnderstanding.parse("Madrid", now: Date(timeIntervalSince1970: now), calendar: utc, gazetteer: g)
    let locator = PlaceLocator(gazetteer: g)
    let u = parsed.resolvingPlaces(locations: [(madrid.0, madrid.1)], locator: locator, minimumPhotos: 1)
    #expect(u.isFilterOnly)
    let cands = [cand("late", z: nil, created: day(2024, 8, 2), at: madrid, event: "m:late"),
                 cand("early", z: nil, created: day(2024, 3, 1), at: madrid, event: "m:early"),
                 cand("early2", z: nil, created: day(2024, 3, 1) + 60, at: madrid, event: "m:early"),
                 cand("lisbon", z: nil, created: day(2024, 3, 1), at: lisbon, event: "m:lisbon"),
                 cand("nowhere", z: nil, created: day(2024, 3, 1))]
    var ctx = FindSearch.Context(scales: [], understanding: u, locator: locator, calendar: utc, now: now)
    ctx.locationUnchecked = 7
    var hard = FindConfig.v2
    hard.placeMode = .hard
    let r = FindSearch.rank(cands, context: ctx, config: hard)
    // A place-only answer keeps its place hard even in soft mode: with nothing to rank by, the unlocated can't compete.
    #expect(ids(FindSearch.rank(cands, context: ctx, config: .v2)) == ids(r))
    #expect(r.filterOnly && ids(r) == ["early", "early2", "late"] && r.weaker.isEmpty)
    #expect(r.sections.map(\.eventId) == ["m:early", "m:late"])
    #expect(r.missingLocation == 1 && r.locationUnchecked == 7)
    var result = r
    FindSearch.fillRest(&result, members: ["m:early": ["early", "x1", "early2", "x2"], "m:late": ["late"]])
    #expect(result.sections.map(\.rest) == [["x1", "x2"], []])
  }

  @Test func softPlacesDropOnlyWhatIsLocatedElsewhere() throws {
    let g = try Gazetteer.load()
    let madrid = (40.4165, -3.7026), lisbon = (38.7167, -9.1333)  // public city centres
    let locator = PlaceLocator(gazetteer: g)
    func understood(_ mode: FindConfig.PlaceMode) -> QueryUnderstanding.Understanding {
      var config = FindConfig.v2
      config.placeMode = mode
      return QueryUnderstanding.parse("Madrid trip", now: Date(timeIntervalSince1970: now), calendar: utc, gazetteer: g,
                                      options: config.parseOptions)
        .resolvingPlaces(locations: [(madrid.0, madrid.1)], locator: locator, minimumPhotos: 1)
    }
    let soft = understood(.soft)
    #expect(soft.semanticText == "Madrid trip" && soft.hasPlaceFilter && !soft.isFilterOnly)
    #expect(understood(.hard).semanticText == "trip" && understood(.hard).isFilterOnly)
    let cands = [cand("there", z: 0.5, at: madrid), cand("thereWeak", z: -0.6, at: madrid),
                 cand("lisbon", z: 5, at: lisbon), cand("album", z: 2.5), cand("albumWeak", z: 1.5)]
    var ctx = context(soft, locator: locator)
    ctx.locationUnchecked = 3
    let r = FindSearch.rank(cands, context: ctx, config: .v2)
    // Located elsewhere: out however well it scores. Located there: filtered gate (1) after the bonus (1).
    // Unlocated: competes on meaning alone at the plain gate (2).
    #expect(Set(ids(r) + r.weaker.map(\.id)) == ["album", "there"])
    #expect(r.matches.first { $0.id == "there" }?.bonus == 1)
    #expect(r.missingLocation == 0 && r.locationUnchecked == 0 && !r.filterOnly)
    var hard = FindConfig.v2
    hard.placeMode = .hard
    let h = FindSearch.rank(cands, context: ctx, config: hard)
    #expect((ids(h) + h.weaker.map(\.id)).isEmpty && !h.filterOnly)  // z 0.5 < 1, no bonus; unlocated dropped
    #expect(h.missingLocation == 2 && h.locationUnchecked == 3)
    var bigger = FindConfig.v2
    bigger.placeBonus = 2
    #expect(Set(ids(FindSearch.rank(cands, context: ctx, config: bigger))).isSuperset(of: ["there", "thereWeak"]))
    // The engine's prefilter agrees: a located-there photo may qualify from its bonus, an unlocated one only at zGate.
    #expect(FindSearch.mayQualify(z: 0.1, coverage: 0, tagCoverage: 0, filtered: true, filterOnly: false,
                                  placeBonus: 1, config: .v2))
    #expect(!FindSearch.mayQualify(z: 1.5, coverage: 0, tagCoverage: 0, filtered: false, filterOnly: false,
                                   config: .v2))
  }

  @Test func eventSupportLiftsOrderAndSurvival() {
    let party = (0..<5).map { cand("party\($0)", z: 2.2, event: "m:party") }
    let cands = party + [cand("joins", z: 1.4, event: "m:party"), cand("alone", z: 1.4, event: "m:other"),
                         cand("solo", z: 2.6, event: "m:solo")]
    let v0 = FindSearch.rank(cands, context: context(), config: .v0)
    #expect(ids(v0).first == "solo" && !ids(v0).contains("joins"))
    let r = FindSearch.rank(cands, context: context(), config: .v3)
    #expect(ids(r).contains("joins") && !ids(r).contains("alone"))
    #expect(ids(r) == party.map(\.asset.id) + ["solo", "joins"])  // 2.6 alone now trails 2.2 + 0.8 support
    #expect(r.matches.first { $0.id == "party0" }?.bonus == 0.8)  // 4 others of a saturation of 5
    #expect(r.sections.first?.eventId == "m:party" && r.sections.first?.matches.count == 6)
    var trips = FindConfig.v3
    trips.supportLevel = .trip
    let spread = [cand("t1", z: 2.5, event: "m:a", trip: "t:x"), cand("t2", z: 2.5, event: "m:b", trip: "t:x"),
                  cand("t3", z: 1.7, event: "m:c", trip: "t:x")]
    let byTrip = FindSearch.rank(spread, context: context(), config: trips)
    #expect(ids(byTrip).contains("t3") && byTrip.sections.map(\.eventId) == ["t:x"])
    trips.supportMeasure = .zMass
    let mass = FindSearch.rank(spread, context: context(), config: trips).matches.first { $0.id == "t3" }?.bonus
    #expect(abs((mass ?? 0) - 1) < 1e-4)
  }

  @Test func tagsQualifyAndReorder() {
    let cands = [cand("tagged", z: 1, tags: 1), cand("plain", z: 2.1), cand("half", z: 2.1, tags: 0.5)]
    #expect(ids(FindSearch.rank(cands, context: context(), config: .v0)) == ["half", "plain"])
    let r = FindSearch.rank(cands, context: context(), config: .v4)
    #expect(ids(r).first == "half" && Set(ids(r) + r.weaker.map(\.id)) == ["tagged", "plain", "half"])
    #expect(TagFusion.coverage(queryTerms: ["soccer"], labels: ["Sport", "grass"]) == 1)
    #expect(TagFusion.coverage(queryTerms: ["soccer", "night"], labels: ["ball"]) == 0.5)
    #expect(TagFusion.coverage(queryTerms: ["wedding"], labels: ["Wedding Dress"]) == 1)
    #expect(TagFusion.coverage(queryTerms: ["dog"], labels: ["cat"]) == 0)
    #expect(TagFusion.coverage(queryTerms: [], labels: ["dog"]) == 0)
  }

  @Test func theTagIndexAgreesWithPerPhotoCoverage() {
    var rng = SeededRNG(seed: 11)
    let vocabulary = ["sport", "ball", "Grass", "beach", "sand", "Wedding Dress", "dog", "pet", "cake", "outdoor",
                      "sky", "food", "dessert", "snow", "stage"]
    var labels: [String: [String]] = [:]
    for i in 0..<400 where i % 7 != 0 {
      labels["p\(i)"] = (0..<Int.random(in: 1...6, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }
    }
    let index = TagIndex(labels: labels)
    #expect(index.photoCount == labels.count && !index.isEmpty && TagIndex.empty.isEmpty)
    for terms in [["soccer"], ["soccer", "night"], ["wedding"], ["dog", "beach"], ["birthday", "food"], ["zebra"], []] {
      let fast = index.coverage(queryTerms: terms)
      for (id, list) in labels {
        let slow = TagFusion.coverage(queryTerms: terms, labels: list)
        #expect((fast[id] ?? 0) == slow, "\(terms) \(id)")
      }
    }
  }

  @Test func seedsBlendIntoMeaning() {
    let cands = [cand("liked", z: 1.5, seedZ: 4), cand("words", z: 3, seedZ: -1)]
    #expect(ids(FindSearch.rank(cands, context: context(), config: .v5)) == ["words"])  // no seed scale: ignored
    let r = FindSearch.rank(cands, context: context(seed: true), config: .v5)
    // (0.5·1.5 + 0.5·4) / √0.5 = 3.9 passes; (0.5·3 − 0.5·1) / √0.5 = 1.4 fails the gate.
    #expect(ids(r) == ["liked"])
    var onlySeed = FindConfig.v5
    onlySeed.seedAlpha = 1
    #expect(FindSearch.rank([cand("x", z: nil, seedZ: 3)], context: context(scales: [], seed: true),
                            config: onlySeed).matches.first.map { abs($0.z! - 3) < 1e-4 } == true)
  }

  @Test func mayQualifyNeverDropsWhatCouldSurvive() {
    var config = FindConfig.v3
    #expect(FindSearch.mayQualify(z: 1.1, coverage: 0, tagCoverage: 0, filtered: false, filterOnly: false,
                                  config: config))
    #expect(!FindSearch.mayQualify(z: 0.9, coverage: 0, tagCoverage: 0, filtered: false, filterOnly: false,
                                   config: config))
    config.understanding = true
    #expect(FindSearch.mayQualify(z: 0.1, coverage: 0, tagCoverage: 0, filtered: true, filterOnly: false,
                                  config: config))
    #expect(FindSearch.mayQualify(z: nil, coverage: 0, tagCoverage: 0, filtered: true, filterOnly: true,
                                  config: .v0))
    #expect(FindSearch.mayQualify(z: nil, coverage: 0.5, tagCoverage: 0, filtered: false, filterOnly: false,
                                  config: .v0))
    #expect(FindSearch.mayQualify(z: 0, coverage: 0, tagCoverage: 0.6, filtered: false, filterOnly: false,
                                  config: .v4))
    #expect(!FindSearch.mayQualify(z: 1.99, coverage: 0, tagCoverage: 0.6, filtered: false, filterOnly: false,
                                   config: .v0))
  }
}
