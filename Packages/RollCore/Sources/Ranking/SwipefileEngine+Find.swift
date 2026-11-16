import Foundation
import Places
import Store

// MARK: - Find (typed search with variants)

extension SwipefileEngine {
  /// Typed search over the whole live index with `config`'s variants (`FindSearch`). With the default config this is
  /// today's Ask Roll answer (`search` returns it as a `PhotoSearch.Result`).
  ///
  /// - `seeds`: photo ids for "more like these" (V5); their mean vector is one more query in the same `dotAll`.
  /// - `tags` (V4, with `config.tags`): the photos' scene labels folded, matched to the query's words by `TagFusion`.
  ///   Nil: the store's (`Repositories.tagLabels` at `config.tagMinConfidence`), loaded once per tag write and kept in
  ///   memory with the candidate rows.
  ///
  /// Uses the piles' fast path (`poolScores`): in-memory rows with date, location and moment, one matrix product. Only
  /// photos that may qualify (`FindSearch.mayQualify`) and pass the query's filters are read from the database; those
  /// failing a filter for lack of a date or location go to the ranker as is, to be counted. `elapsed` covers
  /// understanding, embedding, scoring and ranking.
  public func find(_ text: String, config: FindConfig = .default, seeds: [String] = [],
                   tags: TagIndex? = nil, refinement: PhotoSearch.Refinement = .init()) async throws
    -> FindSearch.Result {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return FindSearch.Result() }
    guard embedder.revision == vectors.revision else { throw EngineError.revisionMismatch }
    guard embedder.dimensions == vectors.dimensions else {
      throw EngineError.dimensionMismatch(embedder: embedder.dimensions, index: vectors.dimensions)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let nowValue = now()
    var steps: [String: Double] = [:]
    var mark = start
    func lap(_ step: String) {
      let t = clock.now
      steps[step, default: 0] += SearchTimings.ms(t - mark)
      mark = t
    }
    let calendar = Calendar.current

    // Understanding (V2): dates and places filter, the rest is embedded.
    var understanding: QueryUnderstanding.Understanding? = nil
    var locator: PlaceLocator? = nil
    if config.understanding {
      let gazetteer = try? Gazetteer.load()
      var u = QueryUnderstanding.parse(text, now: Date(timeIntervalSince1970: nowValue), calendar: calendar,
                                       gazetteer: gazetteer, options: config.parseOptions)
      if u.hasPlaceFilter, let gazetteer {
        let place = PlaceLocator(gazetteer: gazetteer)
        let rows = try await candidatePool.snapshot().snapshot.rows
        let located = rows.compactMap { row -> (latitude: Double, longitude: Double)? in
          guard row.embedded, let lat = row.lat, let lon = row.lon else { return nil }
          return (lat, lon)
        }
        u = u.resolvingPlaces(locations: located, locator: place, minimumPhotos: config.minimumPhotosPerPlace)
        locator = place
      }
      understanding = u
    }
    lap("understand")
    let filtered = understanding?.hasFilter == true
    let semantic = understanding?.semanticText ?? text
    let filterOnly = filtered && understanding!.isFilterOnly
    let soft = FindSearch.softPlaces(understanding, filterOnly: filterOnly, config: config)
    let texts = filterOnly ? [] : FindQuery.texts(for: semantic.isEmpty ? text : semantic, config: config)

    // Queries: the texts, then the seed centroid.
    var queries: [[Float]] = []
    for t in texts { queries.append(Self.normalized(try await embedder.embed(query: t))) }
    let seedVector = try await seedCentroid(seeds)
    if let seedVector { queries.append(seedVector) }
    let placeholder = queries.isEmpty
    if placeholder { queries.append([Float](repeating: 0, count: vectors.dimensions)) }
    lap("embed")

    let terms = SearchTerms.queryTerms(filterOnly ? "" : (semantic.isEmpty ? text : semantic))
    let coverage = terms.isEmpty ? [:] : (try await keywordCoverage?(terms) ?? [:])
    var tagCoverage: [String: Double] = [:]
    if config.tags, !terms.isEmpty {
      var index = tags
      if index == nil { index = try await candidatePool.tagIndex(minConfidence: config.tagMinConfidence) }
      tagCoverage = index?.coverage(queryTerms: terms) ?? [:]
    }
    lap("words")
    let pool = try await poolScores(queries: queries, preset: nil, filter: .none, decidedIn: nil, excluding: [])
    let scales = placeholder ? [] : (0..<texts.count).map { QueryScale(pool.dots, query: $0) }
    let seedScale = seedVector == nil ? nil : QueryScale(pool.dots, query: texts.count)
    let needEvents = config.events || config.groupByEvent || config.expandRest || filterOnly
      || config.supportLevel == .trip
    lap("pool")
    let events = needEvents ? try await eventsById() : [:]
    lap("events")

    // Per entry: meaning z, prefilter, filters.
    var topCosine: Float? = nil
    var read: [String: FindSearch.Candidate] = [:]
    var unread: [FindSearch.Candidate] = []
    let dots = (0..<queries.count).map { pool.dots(query: $0) }  // per query, one per entry
    let wantZs = !config.nothingFound.isOff
    var topZs = TopFloats(count: max(config.nothingFound.gapRank, 1))
    let lenientConfined = filtered && config.filteredZGate < config.zGate
    let maxPlaceBonus = soft ? max(config.placeBonus, 0) : 0
    for k in 0..<pool.count {
      if !scales.isEmpty { topCosine = max(topCosine ?? dots[0][k], dots[0][k]) }
      let seedCosine = seedVector == nil ? nil : dots[texts.count][k]
      let z = FindSearch.meaningZ(count: scales.count, cosine: { dots[$0][k] }, seedCosine: seedCosine,
                                  scales: scales, seedScale: seedScale, config: config)
      if wantZs, let z { topZs.insert(z) }
      let lookedUp = coverage.isEmpty && tagCoverage.isEmpty ? nil : pool.id(k)
      let words = lookedUp.map { coverage[$0] ?? 0 } ?? 0
      let tags = lookedUp.map { tagCoverage[$0] ?? 0 } ?? 0
      // Most photos can't qualify even at the most lenient gate with the largest bonus: skip their filter verdict.
      guard FindSearch.mayQualify(z: z, coverage: words, tagCoverage: tags, filtered: lenientConfined,
                                  filterOnly: filterOnly, placeBonus: maxPlaceBonus, config: config) else { continue }
      let id = lookedUp ?? pool.id(k)
      let row = pool.row(k)
      let v = filtered ? FindSearch.verdict(understanding, soft: soft, created: row.created, latitude: row.lat,
                                            longitude: row.lon, locator: locator, calendar: calendar, config: config)
        : FindSearch.Verdict()
      guard !filtered || FindSearch.mayQualify(z: z, coverage: words, tagCoverage: tags, filtered: v.confined,
                                               filterOnly: filterOnly, placeBonus: v.placeBonus, config: config)
      else { continue }
      if !v.passes {
        if !v.dateOK {
          guard row.created == nil else { continue }  // dated outside the window
        } else if soft || (row.lat != nil && row.lon != nil) {
          continue  // located elsewhere
        }
      }
      let candidate = FindSearch.Candidate(
        asset: SearchAsset(id: id, mediaType: row.asset.mediaType, estBytes: row.asset.estBytes, created: row.created,
                           isFavorite: false, originalLocal: nil),
        cosines: (0..<scales.count).map { dots[$0][k] }, seedCosine: seedCosine, coverage: words,
        tagCoverage: tags, latitude: row.lat, longitude: row.lon, eventId: row.eventId,
        tripId: row.eventId.flatMap { events[$0]?.tripId })
      if v.passes { read[id] = candidate } else { unread.append(candidate) }  // no date or location: only counted
    }
    lap("filter")
    // Favorite and "on this iPhone" come from SQL. Read them for the answer only, after ranking, unless the "only on
    // this iPhone" refinement needs them to rank.
    var candidates = unread
    let readFirst = refinement.onlyOnThisIPhone
    if readFirst {
      for asset in try await repositories.searchAssets(ids: Array(read.keys)) {
        guard var c = read[asset.id] else { continue }
        c.asset = asset
        candidates.append(c)
      }
    } else {
      candidates.append(contentsOf: read.values)
    }

    lap("read")
    let topZ = config.nothingFound.isOff ? nil : topZs.descending
    let unchecked = understanding?.hasPlaceFilter == true ? try await repositories.locationUncheckedCount() : 0
    let context = FindSearch.Context(
      scales: scales, seedScale: seedScale, understanding: understanding, locator: locator,
      lookup: SearchTerms.isLookup(terms), compared: pool.count, topCosine: topCosine, topZ: topZ, events: events,
      locationUnchecked: unchecked, calendar: calendar, now: nowValue, refinement: refinement)
    var result = FindSearch.rank(candidates, context: context, config: config)
    lap("rank")
    if !readFirst, !result.nothingFound {
      let shown = result.matches.map(\.id) + result.weaker.map(\.id)
      let assets = try await repositories.searchAssets(ids: shown)
      FindSearch.replaceAssets(&result, with: Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }
    lap("read")
    if config.expandRest, !result.sections.isEmpty {
      FindSearch.fillRest(&result, members: try await members(rows: pool.libraryRows, events: events))
    }
    lap("rest")
    result.steps = steps
    result.elapsed = clock.now - start
    return result
  }

  /// The normalized mean of the seeds' stored vectors; nil without any.
  func seedCentroid(_ seeds: [String]) async throws -> [Float]? {
    var sum = [Float](repeating: 0, count: vectors.dimensions)
    var n = 0
    for id in seeds {
      guard let v = await vectors.vector(for: id), v.count == sum.count else { continue }
      for i in v.indices { sum[i] += v[i] }
      n += 1
    }
    return n > 0 ? Self.normalized(sum) : nil
  }

  /// The events table by id, read again only after a ranking-relevant write (event ids live on asset rows).
  func eventsById() async throws -> [String: EventRecord] {
    let generation = try await candidatePool.snapshot().snapshot.generation
    if let eventCache, eventCache.generation == generation { return eventCache.events }
    let events = Dictionary(try await repositories.events().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    eventCache = (generation, events)
    return events
  }

  /// Every moment's and trip's photo ids, in time order, from the live, embedded rows; built once per rows generation.
  func members(rows: [RankingRow], events: [String: EventRecord]) async throws -> [String: [String]] {
    let generation = try await candidatePool.snapshot().snapshot.generation
    if let memberCache, memberCache.generation == generation { return memberCache.members }
    var out: [String: [(Double, String)]] = [:]
    for row in rows where row.embedded {
      guard let moment = row.eventId else { continue }
      let entry = (row.created ?? 0, row.asset.id)
      out[moment, default: []].append(entry)
      if let trip = events[moment]?.tripId { out[trip, default: []].append(entry) }
    }
    let members = out.mapValues { $0.sorted { $0 < $1 }.map(\.1) }
    memberCache = (generation, members)
    return members
  }

}
