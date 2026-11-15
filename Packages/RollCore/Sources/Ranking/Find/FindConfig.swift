import Foundation

/// Every knob of typed search (`FindSearch`), so the find eval (`scripts/eval`, find-eval) can switch each variant on
/// and tune it offline with the app's own code. `FindConfig()` is V0, exactly today's Ask Roll answer (ADR-0005:
/// z >= `QueryScale.zGate` or words >= `LibrarySearch.coverageGate`, `LibrarySearch.fusedScore`, folded at
/// `Fold.defaultRatio`). Starting values below are first guesses with their reasons; the eval sets the shipped ones
/// (ADR-0006).
///
/// **The cut-off** (which photos survive) is explicit and composable, applied in this order: the z gate (or words, or
/// tags) qualifies; `relativeCut` drops what scores under a share of the best; `maxResults` caps the length; what is
/// left under `foldRatio` × the best is "weaker". `nothingFound` refuses the whole query before any of that.
public struct FindConfig: Sendable, Equatable, Codable {
  public enum Combine: String, Sendable, Codable {
    /// A photo's meaning is its best z over the query texts: one good phrasing is enough.
    case max
    /// The mean z: a photo has to fit every phrasing.
    case mean
  }

  public enum SupportMeasure: String, Sendable, Codable {
    /// How many other qualified photos share the event.
    case count
    /// The sum of their z (only the positive part): a few clear matches count like many borderline ones.
    case zMass
  }

  public enum SupportLevel: String, Sendable, Codable {
    /// Moments (one outing).
    case moment
    /// Trips where a moment has one, else the moment.
    case trip
  }

  // MARK: Cut-off

  /// A photo's meaning qualifies it from this z (after the seed blend and the event bonus). 2 is today's gate; the
  /// find eval (49 judged queries) measured it keeps a median 941 photos at 26 % precision; z >= 3 kept 165 at 39 %.
  public var zGate: Float = QueryScale.zGate
  /// Words alone qualify a photo from this share of the query's words (`LibrarySearch.coverageGate`).
  public var coverageGate: Double = LibrarySearch.coverageGate
  /// Keep only fused scores >= this × the best (nil: off, today). The eval's best F1 was at 0.6 (P .54, R .58, median
  /// 130 photos); 0.7 gave P .70, R .44.
  public var relativeCut: Float? = nil
  /// Keep at most this many photos, best first, strong and weaker together (nil: no cap, today). Top-200 gave P .49.
  public var maxResults: Int? = nil
  /// What survives but scores under this × the best is "weaker" (folded; `Fold.defaultRatio`).
  public var foldRatio: Float = Fold.defaultRatio
  /// The query-level "nothing found" test. Off by default: no per-photo cut-off empties nonsense answers (0.6 × top
  /// still kept a median 165 for nonsense), so the eval fits these thresholds on whole-query statistics.
  public var nothingFound = NothingFoundTest()

  // MARK: V1 query templates

  /// Extra phrasings embedded next to the query; "{q}" is replaced by it (e.g. "a photo of {q}").
  public var templates: [String] = []
  /// Embed the bare query too.
  public var includeBareQuery = true
  public var combine: Combine = .max

  // MARK: V2 understanding

  /// Dates and places in the query filter; only the rest is embedded (`QueryUnderstanding`).
  public var understanding = false
  public var understandingOptions = QueryUnderstanding.Options()
  /// The z gate once a date or place filter applies. 1.0: inside a trip or a month most photos are already about the
  /// right thing, so the bar to "stands out from the whole library" can drop (z >= 1 is the top ~16 % of a bell curve).
  public var filteredZGate: Float = 1
  /// A place filters only if at least this many located photos fall in it (`Understanding.resolvingPlaces`).
  public var minimumPhotosPerPlace = 1

  // MARK: V3 events

  /// Photos that qualify on their own lift the other photos of their event: the bonus is added to z before the gate,
  /// so it changes both the order and which photos survive the cut.
  public var events = false
  /// Bonus in z units at saturation. 1: a photo in a well-supported event can overtake an isolated hit one deviation
  /// above it, not more.
  public var supportWeight: Float = 1
  /// Support at which the bonus is full. 5: a handful of matching photos is an event about the query; more add nothing.
  public var supportSaturation: Float = 5
  public var supportMeasure: SupportMeasure = .count
  public var supportLevel: SupportLevel = .moment
  /// Group the answer into sections by event, best first (always for a date- or place-only query).
  public var groupByEvent = false
  /// Each section also lists the event's other photos ("rest of this event").
  public var expandRest = false

  // MARK: V4 tags

  /// Fuse per-photo tag coverage (Vision labels mapped to query words, `TagFusion`) like words.
  public var tags = false
  /// Weight of `tagCoverage^1.5`, as `LibrarySearch.wordsWeight` is for words. 1: half the words' weight, since labels
  /// are guesses about the picture and words are what's written in it.
  public var tagWeight: Float = 1
  /// Tags alone qualify a photo from this coverage (nil: tags only reorder).
  public var tagGate: Double? = 0.5

  // MARK: V5 more like these

  /// With seed photos, meaning is `((1 - α) · z(query) + α · z(seed centroid)) / √((1 - α)² + α²)` (re-standardized so
  /// the gate keeps its meaning), gated and ordered like any z. 0.5: the picked photos and the words count the same.
  public var seedAlpha: Float = 0.5

  public init() {}

  /// Today's behaviour.
  public static let v0 = FindConfig()

  /// What `SwipefileEngine.search` (Ask Roll) uses: V0 until the find eval picks the variants that ship.
  public static let `default` = v0

  /// V0 plus one variant each, for the eval. V1 measured slightly worse than V0 (P@10 .85 vs .86), so templates stay
  /// off by default.
  public static var v1: FindConfig { var c = v0; c.templates = ["a photo of {q}"]; return c }
  public static var v2: FindConfig { var c = v0; c.understanding = true; return c }
  public static var v3: FindConfig { var c = v0; c.events = true; c.groupByEvent = true; return c }
  public static var v4: FindConfig { var c = v0; c.tags = true; return c }
  /// V5 needs seeds passed to the search; the config only sets the blend.
  public static var v5: FindConfig { v0 }
}
