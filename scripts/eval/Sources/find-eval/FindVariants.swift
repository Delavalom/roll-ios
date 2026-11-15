import FindEvalKit
import Foundation
import Places
import Ranking
import Store

/// RollCore's `FindSearch` variants (round 2), one `FindConfig` each.
enum FindVariants {
  static var all: [any FindVariant] {
    func cut(_ ratio: Float) -> FindConfig { var c = FindConfig.v0; c.relativeCut = ratio; return c }
    var v23 = FindConfig.v2; v23.events = true; v23.groupByEvent = true
    var v234 = v23; v234.tags = true
    var nf = FindConfig.v0; nf.nothingFound.minTopCosine = 0.735
    var v5 = FindConfig.v5; v5.seedAlpha = 0.5
    return [
      FindSearchVariant(name: "F0", about: "FindSearch with .v0 (must equal V0 exactly; pool checks it)", config: .v0),
      FindSearchVariant(name: "C60", about: ".v0 + relativeCut 0.6", config: cut(0.6)),
      FindSearchVariant(name: "C70", about: ".v0 + relativeCut 0.7", config: cut(0.7)),
      FindSearchVariant(name: "V2", about: ".v2: dates and places filter, the rest embedded", config: .v2),
      FindSearchVariant(name: "V3", about: ".v3: event support bonus, sections by event", config: .v3),
      FindSearchVariant(name: "V4", about: ".v4: Vision tags (confidence >= 0.3) fused like words", config: .v4),
      FindSearchVariant(name: "V5", about: ".v0 + seeds: the first 3 labelled-relevant ids in V0's top 20, "
                        + "seedAlpha 0.5; seeds removed from the answer (skipped with fewer than 3)",
                        config: v5, seeded: true),
      FindSearchVariant(name: "V23", about: "V2 + V3", config: v23),
      FindSearchVariant(name: "V234", about: "V2 + V3 + V4", config: v234),
      FindSearchVariant(name: "NF", about: ".v0 + nothingFound(minTopCosine 0.735)", config: nf),
    ]
  }
}

/// `SwipefileEngine.find` offline: the same steps over `FindLibrary`, then `FindSearch.rank`.
///
/// Inputs: query texts `Ranking.FindQuery.texts(for: semantic, config:)` (semantic = V2's understood text, which
/// `embed --export` embedded); every text's cosines and `QueryScale` over the whole index; the seed centroid's (V5);
/// words from the store's text index (`keywordCoverage`); per photo the export's created, latitude and longitude, its
/// moment and trip (`EventGrouper` over the export), Vision tags (`TagFusion`). Candidates are the pool entries
/// `FindSearch.mayQualify` lets through and that pass the query's filters, plus those failing a filter only for lack of
/// a date or location (counted, as the engine does). `now` is the export's newest date.
struct FindSearchVariant: FindVariant {
  let name: String
  let about: String
  let config: FindConfig
  var seeded = false

  /// The simulated user picks "more like these" from V0's first 20: the first 3 judged relevant.
  static let seedCount = 3
  static let seedWindow = 20

  func answer(_ query: ResolvedQuery, in lib: FindLibrary) async throws -> VariantAnswer? {
    let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return VariantAnswer(strong: [], weaker: []) }
    let calendar = Calendar.current

    // Seeds (V5) from V0's answer and the labels so far.
    var seeds: [String] = []
    if seeded {
      guard let labels = try lib.labels(query.slug) else {
        throw FindSpec.Invalid("\(name) needs --labels (the seeds are labelled-relevant results)")
      }
      let v0 = try await lib.v0Answer(query)
      let relevant = Set(labels.relevant)
      seeds = Array(v0.ranked.prefix(Self.seedWindow).filter(relevant.contains).prefix(Self.seedCount))
      guard seeds.count == Self.seedCount else { return nil }
    }

    // Understanding (V2).
    var understanding: QueryUnderstanding.Understanding? = nil
    var locator: PlaceLocator? = nil
    if config.understanding {
      let u = Understood.of(text, now: lib.now, gazetteer: try lib.gazetteer(), located: lib.located(), config: config)
      understanding = u.understanding
      locator = u.locator
    }
    let filtered = understanding?.hasFilter == true
    let semantic = understanding?.semanticText ?? text
    let filterOnly = filtered && understanding!.isFilterOnly
    let texts = filterOnly ? [] : Ranking.FindQuery.texts(for: semantic.isEmpty ? text : semantic, config: config)
    let rows = try texts.map { try lib.scores($0) }
    let seedRow = seeds.isEmpty ? nil : lib.seedScores(seeds)
    let scales = rows.map { QueryScale(scores: $0) }
    let seedScale = seedRow.map { QueryScale(scores: $0) }

    let terms = SearchTerms.queryTerms(filterOnly ? "" : (semantic.isEmpty ? text : semantic))
    let coverage = terms.isEmpty ? [:] : try await lib.repositories.keywordCoverage(terms: terms)
    let events = config.events || config.groupByEvent || config.supportLevel == .trip || filterOnly
      ? try lib.events() : nil
    let tags = config.tags ? lib.tags() : [:]

    var zs: [Float] = []
    var topCosine: Float? = nil
    var read: [String: FindSearch.Candidate] = [:]
    var unread: [String: FindSearch.Candidate] = [:]
    let wantZs = !config.nothingFound.isOff
    for r in 0..<lib.ids.count where lib.pooled[r] {
      if !scales.isEmpty { topCosine = max(topCosine ?? rows[0][r], rows[0][r]) }
      let seedCosine = seedRow?[r]
      let z = FindSearch.meaningZ(cosines: rows.map { $0[r] }, seedCosine: seedCosine, scales: scales,
                                  seedScale: seedScale, config: config)
      if wantZs, let z { zs.append(z) }
      let id = lib.ids[r]
      let tagCoverage = config.tags ? TagFusion.coverage(queryTerms: terms, labels: tags[id] ?? []) : 0
      guard FindSearch.mayQualify(z: z, coverage: coverage[id] ?? 0, tagCoverage: tagCoverage, filtered: filtered,
                                  filterOnly: filterOnly, config: config) else { continue }
      let created = lib.created(id)
      let (lat, lon) = lib.location(id)
      let moment = events?.assignment[id]
      let candidate = FindSearch.Candidate(
        asset: SearchAsset(id: id, mediaType: 0, estBytes: 0, created: created, isFavorite: false, originalLocal: nil),
        cosines: rows.map { $0[r] }, seedCosine: seedCosine, coverage: coverage[id] ?? 0, tagCoverage: tagCoverage,
        latitude: lat, longitude: lon, eventId: moment, tripId: moment.flatMap { events?.tripOf[$0] })
      if let u = understanding, filtered {
        let dateOK = u.matchesDate(created, calendar: calendar)
        guard dateOK || created == nil else { continue }
        let placeOK = dateOK && u.matchesPlace(latitude: lat, longitude: lon, locator: locator)
        if !(dateOK && placeOK) {
          if dateOK, lat != nil, lon != nil { continue }  // located elsewhere
          unread[id] = candidate  // no date or no location: only counted
          continue
        }
      }
      read[id] = candidate
    }
    // The store's search fields for every candidate; `created` stays the export's (the database copy may be older).
    var candidates: [FindSearch.Candidate] = []
    for asset in try await lib.repositories.searchAssets(ids: Array(read.keys) + Array(unread.keys)) {
      guard var c = read[asset.id] ?? unread[asset.id] else { continue }
      var a = asset
      if !lib.export.isEmpty { a.created = c.asset.created }
      c.asset = a
      candidates.append(c)
    }

    let topZ = config.nothingFound.isOff ? nil : Array(zs.sorted(by: >).prefix(max(config.nothingFound.gapRank, 1)))
    let context = FindSearch.Context(
      scales: scales, seedScale: seedScale, understanding: understanding, locator: locator,
      lookup: SearchTerms.isLookup(terms), compared: lib.poolCount, topCosine: topCosine, topZ: topZ, events: [:],
      calendar: calendar, now: lib.now)
    let result = FindSearch.rank(candidates, context: context, config: config)

    let seedSet = Set(seeds)
    let strong = result.matches.filter { !seedSet.contains($0.id) }
    let weaker = result.weaker.filter { !seedSet.contains($0.id) }
    var notes: [String: Double] = ["texts": Double(texts.count), "wordHits": Double(coverage.count)]
    if let t = result.topZ { notes["zTop"] = Double(t) }
    if let t = result.topCosine { notes["cosTop"] = Double(t) }
    if result.nothingFound { notes["nothingFound"] = 1 }
    if let u = result.understanding, u.hasFilter {
      notes["filtered"] = 1
      notes["filterOnly"] = result.filterOnly ? 1 : 0
      notes["missingDate"] = Double(result.missingDate)
      notes["missingLocation"] = Double(result.missingLocation)
    }
    if config.groupByEvent { notes["sections"] = Double(result.sections.count) }
    if seeded { notes["seeds"] = Double(seeds.count) }
    return VariantAnswer(strong: strong.map(\.id), weaker: weaker.map(\.id), notes: notes,
                         scores: (strong + weaker).map(\.score))
  }
}

extension FindLibrary {
  /// V0's answer for `query`, computed once per run.
  func v0Answer(_ query: ResolvedQuery) async throws -> VariantAnswer {
    let key = "V0/\(query.slug)"
    if let a = answers[key] { return a }
    guard let v0 = Variants.all.first(where: { $0.name == "V0" }),
          let a = try await v0.answer(query, in: self) else { throw FindSpec.Invalid("V0 has no answer") }
    answers[key] = a
    return a
  }
}
