import Foundation
import Places
import Store

extension FindSearch {
  /// Ranks `candidates` (see `FindSearch`). Pure; `context.locator` is mutated only as a cache.
  public static func rank(_ candidates: [Candidate], context: Context, config: FindConfig = .v0) -> Result {
    var result = Result()
    result.compared = context.compared ?? candidates.count
    let u = config.understanding ? context.understanding : nil
    result.understanding = u
    let filtered = u?.hasFilter == true
    let filterOnly = filtered && (u!.isFilterOnly || context.scales.isEmpty)
    result.filterOnly = filterOnly
    let soft = softPlaces(u, filterOnly: filterOnly, config: config)
    if u?.hasPlaceFilter == true, !soft { result.locationUnchecked = context.locationUnchecked }

    // 1-3: meaning, filters, own qualification.
    struct Entry {
      var index: Int
      var z: Float?
      var passes: Bool
      var own: Bool
      var words: Bool
      var gate: Float
      /// Event bonus plus the soft place bonus.
      var bonus: Float = 0
    }
    var entries: [Entry] = []
    entries.reserveCapacity(candidates.count)
    var meaning: [Float] = []
    for (i, c) in candidates.enumerated() {
      let z = meaningZ(cosines: c.cosines, seedCosine: c.seedCosine, scales: context.scales,
                       seedScale: context.seedScale, config: config)
      if let z { meaning.append(z) }
      let words = c.coverage >= config.coverageGate
        || (config.tags && config.tagGate.map { c.tagCoverage >= $0 } == true)
      let v = verdict(u, soft: soft, created: c.asset.created, latitude: c.latitude, longitude: c.longitude,
                      locator: context.locator, calendar: context.calendar, config: config)
      let gate = v.confined ? config.filteredZGate : config.zGate
      let own = filterOnly || words || (z.map { $0 + v.placeBonus >= gate } ?? false)
      // Counted when it could have qualified: on its own, or with the most an event could add. Soft places keep
      // photos without a location, so none is missing one.
      let eventMost = config.events ? config.supportWeight : 0
      if let u, filtered, own || (z.map { $0 + v.placeBonus + eventMost >= gate } ?? false) {
        if !v.dateOK, u.hasDateFilter, c.asset.created == nil { result.missingDate += 1 }
        if !soft, v.dateOK, !v.passes, u.hasPlaceFilter, c.latitude == nil || c.longitude == nil {
          result.missingLocation += 1
        }
      }
      entries.append(Entry(index: i, z: z, passes: v.passes, own: own, words: words, gate: gate, bonus: v.placeBonus))
    }

    // The whole query refused?
    let top = context.topZ
      ?? (config.nothingFound.isOff ? (meaning.max().map { [$0] } ?? []) : meaning.sorted(by: >))
    result.topZ = top.first
    result.topCosine = context.topCosine
    let k = max(config.nothingFound.gapRank, 1)
    if top.count >= k { result.topGap = top[0] - top[k - 1] }
    if !filterOnly, !config.nothingFound.isOff, !entries.contains(where: { $0.passes && $0.words }),
       config.nothingFound.refuses(topZ: top, topCosine: context.topCosine) {
      result.nothingFound = true
      return result
    }

    // 4: event support among photos that pass and qualify on their own.
    func key(_ c: Candidate) -> String? {
      config.supportLevel == .trip ? (c.tripId ?? c.eventId) : c.eventId
    }
    if config.events, !filterOnly, config.supportSaturation > 0 {
      func weight(_ e: Entry) -> Float { config.supportMeasure == .count ? 1 : max(e.z ?? 0, 0) }
      var support: [String: Float] = [:]
      for e in entries where e.passes && e.own {
        if let k = key(candidates[e.index]) { support[k, default: 0] += weight(e) }
      }
      for i in entries.indices where entries[i].passes {
        guard let k = key(candidates[entries[i].index]), var s = support[k] else { continue }
        if entries[i].own { s -= weight(entries[i]) }
        entries[i].bonus += config.supportWeight * min(max(s, 0) / config.supportSaturation, 1)
      }
    }

    // 5: score and cut.
    struct Scored {
      var entry: Entry
      var score: Float
    }
    var scored: [Scored] = []
    for e in entries where e.passes {
      let lifted = e.z.map { $0 + e.bonus }
      guard e.own || (lifted.map { $0 >= e.gate } ?? false) else { continue }
      let c = candidates[e.index]
      var s = LibrarySearch.fusedScore(z: lifted, coverage: c.coverage, lookup: context.lookup)
      if config.tags { s += config.tagWeight * Float(pow(min(max(c.tagCoverage, 0), 1), 1.5)) }
      scored.append(Scored(entry: e, score: s))
    }
    guard let best = scored.map(\.score).max() else { return result }
    if let ratio = config.relativeCut, best > 0 { scored.removeAll { $0.score < ratio * best } }
    func asset(_ s: Scored) -> SearchAsset { candidates[s.entry.index].asset }
    if filterOnly {
      scored.sort { a, b in
        let ta = asset(a).created ?? .infinity, tb = asset(b).created ?? .infinity
        return ta != tb ? ta < tb : asset(a).id < asset(b).id
      }
    } else {
      scored.sort { $0.score != $1.score ? $0.score > $1.score : asset($0).id < asset($1).id }
    }
    if let cap = config.maxResults, scored.count > cap { scored.removeLast(scored.count - max(cap, 0)) }

    let cutoff = context.now - PhotoSearch.yearSeconds
    let refinement = context.refinement
    var kept = scored.enumerated().filter { _, s in
      let a = asset(s)
      if refinement.olderThanAYear, !(a.created.map { $0 < cutoff } ?? false) { return false }
      if refinement.onlyOnThisIPhone, a.originalLocal != true { return false }
      return true
    }
    if refinement.biggestFirst {
      kept.sort { x, y in
        let bx = asset(x.element).estBytes, by = asset(y.element).estBytes
        return bx != by ? bx > by : x.offset < y.offset
      }
    }
    for (_, s) in kept {
      let c = candidates[s.entry.index]
      let match = Match(asset: c.asset, score: s.score, z: s.entry.z, coverage: c.coverage,
                        tagCoverage: config.tags ? c.tagCoverage : 0, bonus: s.entry.bonus, eventId: key(c))
      if Fold.isWeak(s.score, top: best, ratio: config.foldRatio) { result.weaker.append(match) } else {
        result.matches.append(match)
      }
    }
    result.totalBytes = result.matches.reduce(0) { $0 + $1.estBytes }
    result.favorites = result.matches.filter(\.asset.isFavorite).count
    if config.groupByEvent || filterOnly {
      result.sections = sections(result.matches, events: context.events, byTime: filterOnly)
    }
    return result
  }

  /// Where one photo stands against the query's filters (V2): `rank` and the engine's prefilter share it.
  public struct Verdict: Sendable, Equatable {
    /// It stays a candidate.
    public var passes = true
    public var dateOK = true
    /// Inside a filter (its date window, or located in the place), so `filteredZGate` applies; else `zGate`.
    public var confined = false
    /// Soft places: `FindConfig.placeBonus` when located in the place.
    public var placeBonus: Float = 0

    /// No filter: passes, not confined.
    public init() {}
  }

  /// Whether the query's places are soft (`FindConfig.PlaceMode.soft`) for this answer. A date- or place-only answer
  /// (everything there, by time) keeps them hard: with nothing to rank by, an unlocated photo can't compete.
  public static func softPlaces(_ u: QueryUnderstanding.Understanding?, filterOnly: Bool, config: FindConfig) -> Bool {
    config.placeMode == .soft && u?.hasPlaceFilter == true && !filterOnly
  }

  /// `u`'s filters for one photo (nil `u`: no filter). Hard: it passes when it is in every filter, and then it is
  /// confined. Soft places: a photo located elsewhere fails; one located in the place passes, confined, with the bonus;
  /// one without a location passes, confined only by a date filter.
  public static func verdict(_ u: QueryUnderstanding.Understanding?, soft: Bool, created: Double?, latitude: Double?,
                             longitude: Double?, locator: PlaceLocator?, calendar: Calendar,
                             config: FindConfig) -> Verdict {
    guard let u, u.hasFilter else { return Verdict() }
    var v = Verdict()
    v.dateOK = u.matchesDate(created, calendar: calendar)
    if soft {
      let located = latitude != nil && longitude != nil
      let inside = located && u.matchesPlace(latitude: latitude, longitude: longitude, locator: locator)
      v.passes = v.dateOK && (inside || !located)
      v.confined = u.hasDateFilter || inside
      v.placeBonus = inside ? config.placeBonus : 0
    } else {
      v.passes = v.dateOK && u.matchesPlace(latitude: latitude, longitude: longitude, locator: locator)
      v.confined = true
    }
    return v
  }

  /// A photo's meaning z: each text's z combined (`FindConfig.combine`), blended with the seed's
  /// (`FindConfig.seedAlpha`). Nil without query texts or seeds.
  public static func meaningZ(cosines: [Float], seedCosine: Float?, scales: [QueryScale], seedScale: QueryScale?,
                              config: FindConfig) -> Float? {
    meaningZ(count: min(cosines.count, scales.count), cosine: { cosines[$0] }, seedCosine: seedCosine, scales: scales,
             seedScale: seedScale, config: config)
  }

  /// `meaningZ` without an array per photo (the engine's loop over the library).
  @inline(__always)
  static func meaningZ(count n: Int, cosine: (Int) -> Float, seedCosine: Float?, scales: [QueryScale],
                       seedScale: QueryScale?, config: FindConfig) -> Float? {
    var z: Float? = nil
    if n > 0 {
      var best = -Float.infinity, sum: Float = 0
      for j in 0..<n {
        let v = scales[j].z(cosine(j))
        best = max(best, v)
        sum += v
      }
      z = config.combine == .max ? best : sum / Float(n)
    }
    if let seedCosine, let seedScale {
      let s = seedScale.z(seedCosine)
      // Divided by the blend's own deviation (two independent z's mixed with weights 1-α and α), so the blend is a z
      // again and the same gate means the same rarity: an even blend of 1.5 and 1.5 is 2.1, not 1.5.
      let a = config.seedAlpha, spread = ((1 - a) * (1 - a) + a * a).squareRoot()
      z = z.map { ((1 - a) * $0 + a * s) / max(spread, .ulpOfOne) } ?? s
    }
    return z
  }

  /// Whether a photo can reach the answer before filters and events are looked at: the engine's prefilter, so only
  /// those are read from the database. Errs on the side of yes (the event bonus at its most).
  /// `filtered`: the photo is confined by a filter (`Verdict.confined`), so the lower gate applies; `placeBonus`: its
  /// soft place bonus.
  public static func mayQualify(z: Float?, coverage: Double, tagCoverage: Double, filtered: Bool, filterOnly: Bool,
                                placeBonus: Float = 0, config: FindConfig) -> Bool {
    if filterOnly || coverage >= config.coverageGate { return true }
    if config.tags, let gate = config.tagGate, tagCoverage >= gate { return true }
    guard let z else { return false }
    let gate = (filtered && config.understanding ? config.filteredZGate : config.zGate)
      - (config.events ? max(config.supportWeight, 0) : 0)
    return z + placeBonus >= gate
  }

  /// Groups `matches` by `Match.eventId`: best section first (by time for a date- or place-only answer), photos in no
  /// event last together.
  static func sections(_ matches: [Match], events: [String: EventRecord], byTime: Bool) -> [Section] {
    var order: [String] = []
    var groups: [String: [Match]] = [:]
    var loose: [Match] = []
    for m in matches {
      guard let id = m.eventId else { loose.append(m); continue }
      if groups[id] == nil { order.append(id) }
      groups[id, default: []].append(m)
    }
    var out = order.map { id in
      Section(eventId: id, event: events[id], matches: groups[id]!, score: groups[id]!.map(\.score).max() ?? 0)
    }
    if byTime {
      func start(_ s: Section) -> Double { s.event?.startAt ?? s.matches.compactMap(\.created).min() ?? .infinity }
      out.sort { start($0) != start($1) ? start($0) < start($1) : $0.id < $1.id }
    }
    if !loose.isEmpty { out.append(Section(eventId: nil, event: nil, matches: loose, score: loose.map(\.score).max() ?? 0)) }
    return out
  }

  /// Puts the stored assets (favorite, "on this iPhone") on the answer's matches, read after ranking. A match whose id is
  /// missing (deleted since the rows were cached) is dropped, with its section when that empties it; totals follow.
  public static func replaceAssets(_ result: inout Result, with assets: [String: SearchAsset]) {
    func patch(_ matches: [Match]) -> [Match] {
      matches.compactMap { m in
        guard let a = assets[m.id] else { return nil }
        var m = m
        m.asset = a
        return m
      }
    }
    result.matches = patch(result.matches)
    result.weaker = patch(result.weaker)
    result.sections = result.sections.compactMap { section in
      var section = section
      section.matches = patch(section.matches)
      return section.matches.isEmpty ? nil : section
    }
    result.totalBytes = result.matches.reduce(0) { $0 + $1.estBytes }
    result.favorites = result.matches.filter(\.asset.isFavorite).count
  }

  /// Fills each section's `rest`: `members` (event id → its photo ids in time order) minus what the answer shows.
  public static func fillRest(_ result: inout Result, members: [String: [String]]) {
    let shown = Set(result.matches.map(\.id)).union(result.weaker.map(\.id))
    for i in result.sections.indices {
      guard let id = result.sections[i].eventId else { continue }
      result.sections[i].rest = (members[id] ?? []).filter { !shown.contains($0) }
    }
  }
}
