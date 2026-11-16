import Foundation
import Places
import Store

/// Typed search ("Find"), pure: which photos answer a query, in what order and in what sections, from plain values.
/// `SwipefileEngine.find` embeds the query texts, scores the library in one `dotAll` and calls `rank`; the find eval
/// (`scripts/eval`, find-eval) calls `rank` offline with the same values from its fixtures. With `FindConfig.v0` the
/// answer is exactly `PhotoSearch.rank`'s (ADR-0005).
///
/// Per candidate photo:
/// 1. **Meaning** `z`: each query text's cosine on that text's scale over the library (`QueryScale`), combined by max or
///    mean (V1); blended with the seed centroid's z when seeds are given (V5, `FindConfig.seedAlpha`).
/// 2. **Filters** (V2): the query's dates and places (`QueryUnderstanding`). A photo without a date can't pass a date
///    and is counted (`Result.missingDate`) instead of silently dropped. Places are soft by default
///    (`FindConfig.PlaceMode`): located elsewhere fails, located there gets a bonus, unlocated competes on meaning; hard
///    places drop unlocated photos too and count them (`missingLocation`). See `verdict`.
/// 3. **Qualifies** when z >= the gate (`zGate`, or `filteredZGate` under a filter), or its words or tags cover enough
///    of the query, or (date- or place-only query) when it passes the filters at all.
/// 4. **Event bonus** (V3): photos that qualify on their own support the others in their event; the bonus is added to z
///    before the gate, so it decides both order and survival.
/// 5. **Score** `LibrarySearch.fusedScore` plus the tag term (V4) and the bonus; then the cut-off (`relativeCut`,
///    `maxResults`), the refinement, and the fold into "weaker" (`foldRatio`).
/// 6. **Sections** by event (V3 `groupByEvent`, and always for a date- or place-only query).
///
/// The whole query can be refused first (`FindConfig.nothingFound`).
public enum FindSearch {
  /// One photo that may answer: what the eval's `Variant` seam hands over per asset.
  public struct Candidate: Sendable, Equatable {
    public var asset: SearchAsset
    /// Cosine with each query text, in `Context.scales` order (empty for a date- or place-only query).
    public var cosines: [Float]
    /// Cosine with the seed centroid (V5); nil without seeds.
    public var seedCosine: Float?
    /// Share of the query's words found in the photo's text.
    public var coverage: Double
    /// Share of the query's words its tags cover (`TagFusion.coverage`); used with `FindConfig.tags`.
    public var tagCoverage: Double
    public var latitude: Double?
    public var longitude: Double?
    /// The photo's moment (`EventGrouper`); nil before the event pass or when undated.
    public var eventId: String?
    /// The moment's trip, if any.
    public var tripId: String?

    public init(asset: SearchAsset, cosines: [Float], seedCosine: Float? = nil, coverage: Double = 0,
                tagCoverage: Double = 0, latitude: Double? = nil, longitude: Double? = nil, eventId: String? = nil,
                tripId: String? = nil) {
      self.asset = asset; self.cosines = cosines; self.seedCosine = seedCosine; self.coverage = coverage
      self.tagCoverage = tagCoverage; self.latitude = latitude; self.longitude = longitude; self.eventId = eventId
      self.tripId = tripId
    }
  }

  /// Everything about the query and the library that isn't per photo.
  public struct Context {
    /// One scale per query text, over the whole library (`QueryScale(dots, query:)`).
    public var scales: [QueryScale]
    /// The seed centroid's scale (V5).
    public var seedScale: QueryScale?
    /// The parsed query (V2; used with `FindConfig.understanding`).
    public var understanding: QueryUnderstanding.Understanding?
    /// Place tests for the understanding's places; nil fails every place filter.
    public var locator: PlaceLocator?
    /// `SearchTerms.isLookup` of the query's words: words weigh more, meaning less.
    public var lookup: Bool
    /// How many photos were compared (the live, embedded library); defaults to the candidates.
    public var compared: Int?
    /// The best cosine of the first query text over the library (nothing-found test).
    public var topCosine: Float?
    /// The library's best meaning z values, descending (nothing-found test); nil: taken from the candidates.
    public var topZ: [Float]?
    /// Event id → event, for sections' dates and names (`Repositories.events`); may be empty.
    public var events: [String: EventRecord]
    /// Library rows whose location hasn't been read yet (`Repositories.locationUncheckedCount`), reported as is.
    public var locationUnchecked: Int
    public var calendar: Calendar
    public var now: Double
    public var refinement: PhotoSearch.Refinement

    public init(scales: [QueryScale], seedScale: QueryScale? = nil,
                understanding: QueryUnderstanding.Understanding? = nil, locator: PlaceLocator? = nil,
                lookup: Bool = false, compared: Int? = nil, topCosine: Float? = nil, topZ: [Float]? = nil,
                events: [String: EventRecord] = [:], locationUnchecked: Int = 0, calendar: Calendar = .current,
                now: Double = Date().timeIntervalSince1970, refinement: PhotoSearch.Refinement = .init()) {
      self.scales = scales; self.seedScale = seedScale; self.understanding = understanding; self.locator = locator
      self.lookup = lookup; self.compared = compared; self.topCosine = topCosine; self.topZ = topZ
      self.events = events; self.locationUnchecked = locationUnchecked; self.calendar = calendar; self.now = now
      self.refinement = refinement
    }
  }

  public struct Match: Sendable, Equatable, Identifiable {
    public var asset: SearchAsset
    /// The order of the answer: fused score plus tag term and event bonus.
    public var score: Float
    /// Meaning z after the seed blend, before the bonus; nil for a date- or place-only query.
    public var z: Float?
    public var coverage: Double
    public var tagCoverage: Double
    /// The event bonus (V3) plus the soft place bonus (V2, `FindConfig.placeBonus`), in z units.
    public var bonus: Float
    /// The section this photo is grouped under: its moment, or its trip at `SupportLevel.trip`.
    public var eventId: String?
    public var id: String { asset.id }
    public var estBytes: Int64 { asset.estBytes }
    public var created: Double? { asset.created }
  }

  /// One event of the answer.
  public struct Section: Sendable, Equatable, Identifiable {
    /// The event id; nil for the section of photos in no event.
    public var eventId: String?
    public var event: EventRecord?
    /// In the answer's order.
    public var matches: [Match]
    /// The best match's score.
    public var score: Float
    /// The event's other photos ("rest of this event", `FindSearch.fillRest`), in time order.
    public var rest: [String] = []
    public var id: String { eventId ?? "" }
  }

  public struct Result: Sendable, Equatable {
    public var matches: [Match] = []
    /// Survived the cut but scored under `foldRatio` × the best; same order as `matches`.
    public var weaker: [Match] = []
    /// `matches` grouped by event (V3 `groupByEvent`, or a date- or place-only query); empty otherwise.
    public var sections: [Section] = []
    public var totalBytes: Int64 = 0
    public var favorites = 0
    public var elapsed: Duration = .zero
    /// Milliseconds per step of `SwipefileEngine.find` (understand, embed, words, pool, events, filter, read, rank,
    /// rest), for the QA bench. Empty from `rank` alone.
    public var steps: [String: Double] = [:]
    public var compared = 0
    public var understanding: QueryUnderstanding.Understanding?
    /// Only a date or place: everything in the window, by time.
    public var filterOnly = false
    /// Photos that would have qualified but have no location to test against the query's place (hard places only).
    public var missingLocation = 0
    /// Photos that would have qualified but have no date to test against the query's dates.
    public var missingDate = 0
    /// `Context.locationUnchecked`, when the query has a hard place filter (soft places keep those photos).
    public var locationUnchecked = 0
    /// The query was refused (`FindConfig.nothingFound`).
    public var nothingFound = false
    /// The statistics the nothing-found test saw.
    public var topZ: Float?
    public var topCosine: Float?
    /// Best z minus the `NothingFoundTest.gapRank`-th (when the test is on and there are that many).
    public var topGap: Float?

    public init() {}

    /// The Ask Roll answer (`SwipefileEngine.search`).
    public var photoSearch: PhotoSearch.Result {
      var r = PhotoSearch.Result()
      r.matches = matches.map { PhotoSearch.Match(asset: $0.asset, score: $0.score, coverage: $0.coverage) }
      r.weaker = weaker.map { PhotoSearch.Match(asset: $0.asset, score: $0.score, coverage: $0.coverage) }
      r.totalBytes = totalBytes
      r.favorites = favorites
      r.elapsed = elapsed
      r.compared = compared
      return r
    }
  }
}
