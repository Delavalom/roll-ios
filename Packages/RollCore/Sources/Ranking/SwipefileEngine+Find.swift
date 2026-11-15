import Foundation
import Places
import Store

// MARK: - Find (typed search with variants)

extension SwipefileEngine {
  /// Typed search over the whole live index with `config`'s variants (`FindSearch`). With the default config this is
  /// today's Ask Roll answer (`search` returns it as a `PhotoSearch.Result`).
  ///
  /// - `seeds`: photo ids for "more like these" (V5); their mean vector is one more query in the same `dotAll`.
  /// - `tags`: asset id → labels (V4, with `config.tags`), matched to the query's words by `TagFusion`.
  ///
  /// Uses the piles' fast path (`poolScores`): in-memory rows with date, location and moment, one matrix product. Only
  /// photos that may qualify (`FindSearch.mayQualify`) and pass the query's filters are read from the database; those
  /// failing a filter for lack of a date or location go to the ranker as is, to be counted. `elapsed` covers
  /// understanding, embedding, scoring and ranking.
  public func find(_ text: String, config: FindConfig = .default, seeds: [String] = [],
                   tags: [String: [String]]? = nil, refinement: PhotoSearch.Refinement = .init()) async throws
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
    let calendar = Calendar.current

    // Understanding (V2): dates and places filter, the rest is embedded.
    var understanding: QueryUnderstanding.Understanding? = nil
    var locator: PlaceLocator? = nil
    if config.understanding {
      let gazetteer = try? Gazetteer.load()
      var u = QueryUnderstanding.parse(text, now: Date(timeIntervalSince1970: nowValue), calendar: calendar,
                                       gazetteer: gazetteer, options: config.understandingOptions)
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
    let filtered = understanding?.hasFilter == true
    let semantic = understanding?.semanticText ?? text
    let filterOnly = filtered && understanding!.isFilterOnly
    let texts = filterOnly ? [] : FindQuery.texts(for: semantic.isEmpty ? text : semantic, config: config)

    // Queries: the texts, then the seed centroid.
    var queries: [[Float]] = []
    for t in texts { queries.append(Self.normalized(try await embedder.embed(query: t))) }
    let seedVector = try await seedCentroid(seeds)
    if let seedVector { queries.append(seedVector) }
    let placeholder = queries.isEmpty
    if placeholder { queries.append([Float](repeating: 0, count: vectors.dimensions)) }

    let terms = SearchTerms.queryTerms(filterOnly ? "" : (semantic.isEmpty ? text : semantic))
    let coverage = terms.isEmpty ? [:] : (try await keywordCoverage?(terms) ?? [:])
    let pool = try await poolScores(queries: queries, preset: nil, filter: .none, decidedIn: nil, excluding: [])
    let scales = placeholder ? [] : (0..<texts.count).map { QueryScale(pool.dots, query: $0) }
    let seedScale = seedVector == nil ? nil : QueryScale(pool.dots, query: texts.count)
    let needEvents = config.events || config.groupByEvent || config.expandRest || filterOnly
      || config.supportLevel == .trip
    let events = needEvents ? try await eventsById() : [:]

    // Per entry: meaning z, prefilter, filters.
    var zs: [Float] = []
    var topCosine: Float? = nil
    var read: [String: FindSearch.Candidate] = [:]
    var unread: [FindSearch.Candidate] = []
    let dots = (0..<queries.count).map { pool.dots(query: $0) }  // per query, one per entry
    let wantZs = !config.nothingFound.isOff
    zs.reserveCapacity(wantZs ? pool.count : 0)
    for k in 0..<pool.count {
      if !scales.isEmpty { topCosine = max(topCosine ?? dots[0][k], dots[0][k]) }
      let seedCosine = seedVector == nil ? nil : dots[texts.count][k]
      let z = FindSearch.meaningZ(count: scales.count, cosine: { dots[$0][k] }, seedCosine: seedCosine,
                                  scales: scales, seedScale: seedScale, config: config)
      if wantZs, let z { zs.append(z) }
      let id = pool.id(k)
      let tagCoverage = config.tags ? TagFusion.coverage(queryTerms: terms, labels: tags?[id] ?? []) : 0
      guard FindSearch.mayQualify(z: z, coverage: coverage[id] ?? 0, tagCoverage: tagCoverage, filtered: filtered,
                                  filterOnly: filterOnly, config: config) else { continue }
      let cosines = (0..<scales.count).map { dots[$0][k] }
      let row = pool.row(k)
      let candidate = FindSearch.Candidate(
        asset: SearchAsset(id: id, mediaType: row.asset.mediaType, estBytes: row.asset.estBytes, created: row.created,
                           isFavorite: false, originalLocal: nil),
        cosines: cosines, seedCosine: seedCosine, coverage: coverage[id] ?? 0, tagCoverage: tagCoverage,
        latitude: row.lat, longitude: row.lon, eventId: row.eventId,
        tripId: row.eventId.flatMap { events[$0]?.tripId })
      if let u = understanding, filtered {
        let dateOK = u.matchesDate(row.created, calendar: calendar)
        guard dateOK || row.created == nil else { continue }
        let placeOK = dateOK && u.matchesPlace(latitude: row.lat, longitude: row.lon, locator: locator)
        if !(dateOK && placeOK) {
          if dateOK, row.lat != nil, row.lon != nil { continue }  // located elsewhere
          unread.append(candidate)  // no date or no location: only counted
          continue
        }
      }
      read[id] = candidate
    }
    var candidates = unread
    for asset in try await repositories.searchAssets(ids: Array(read.keys)) {
      guard var c = read[asset.id] else { continue }
      c.asset = asset
      candidates.append(c)
    }

    let topZ = config.nothingFound.isOff ? nil : Array(zs.sorted(by: >).prefix(max(config.nothingFound.gapRank, 1)))
    let unchecked = understanding?.hasPlaceFilter == true ? try await repositories.locationUncheckedCount() : 0
    let context = FindSearch.Context(
      scales: scales, seedScale: seedScale, understanding: understanding, locator: locator,
      lookup: SearchTerms.isLookup(terms), compared: pool.count, topCosine: topCosine, topZ: topZ, events: events,
      locationUnchecked: unchecked, calendar: calendar, now: nowValue, refinement: refinement)
    var result = FindSearch.rank(candidates, context: context, config: config)
    if config.expandRest, !result.sections.isEmpty {
      FindSearch.fillRest(&result, members: members(of: Set(result.sections.compactMap(\.eventId)),
                                                    rows: pool.libraryRows, events: events))
    }
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

  /// Photo ids of each of `ids` (moments or trips), in time order, from the live, embedded rows.
  func members(of ids: Set<String>, rows: [RankingRow], events: [String: EventRecord]) -> [String: [String]] {
    var out: [String: [(Double, String)]] = [:]
    for row in rows where row.embedded {
      guard let moment = row.eventId else { continue }
      for key in [moment, events[moment]?.tripId].compactMap({ $0 }) where ids.contains(key) {
        out[key, default: []].append((row.created ?? 0, row.asset.id))
      }
    }
    return out.mapValues { $0.sorted { $0 < $1 }.map(\.1) }
  }
}
