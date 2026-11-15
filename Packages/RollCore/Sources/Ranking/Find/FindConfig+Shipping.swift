import Foundation

extension FindConfig {
  /// **What the app ships**: Ask Roll answers, "more like these" and living albums all search with this one value,
  /// so tuning it here (from the find eval, ADR-0006) changes every Find surface at once. `default` (V0) stays what
  /// `SwipefileEngine.search` and the eval's baseline use.
  ///
  /// Chosen 2026-11-15 from the judged find eval on the founder's library (49 queries, P@20; ADR-0006):
  /// - **Ranking: V0** (z on the query's own scale, words fused, fold 0.4). V1 templates measured slightly worse.
  /// - **`relativeCut` 0.6**: P@20 unchanged (.823 = V0) with a median answer of 130 photos instead of 676; the best F1
  ///   of the cuts tried (0.7 lost recall).
  /// - **`nothingFound.minTopCosine` 0.735**: refuses queries nothing in the library answers; the app then shows
  ///   "Nothing clearly matched" with the closest few. First fit on the nonsense queries; to be watched.
  /// - **Understanding on, fixed**: holiday words filter by their days *and* stay embedded ("christmas 2023" was P@20
  ///   0.2 ranked by time with all 34 relevant photos in its 98 results); places are soft (`PlaceMode.soft`: album trip
  ///   queries fell from .80 to .48 under the hard filter, since only 18.6 % of the library is located). Dates (months,
  ///   seasons, years, "last week") still filter and leave the text.
  /// - **Tags on, as evaluated (V4)**: Vision labels >= 0.3 fused like words (`tagWeight` 1, `tagGate` 0.5): P@20 .841
  ///   vs .823 (things .69 → .72, events .85 → .90). The tag pass fills them after indexing drains.
  /// - **Events for grouping only**: sections by moment and "rest of this event", no support bonus. As a ranking
  ///   signal (V3) events lowered P@20 to .793.
  public static var shipping: FindConfig {
    var c = FindConfig.v0
    c.relativeCut = 0.6
    c.nothingFound = NothingFoundTest(minTopCosine: 0.735)
    c.understanding = true
    c.understandingOptions.keepHolidayWords = true
    c.placeMode = .soft
    c.tags = true
    c.tagWeight = 1
    c.tagGate = 0.5
    c.tagMinConfidence = 0.3
    c.events = false
    c.supportWeight = 0
    c.groupByEvent = true
    c.expandRest = true
    return c
  }

  /// `self` without the query-level refusal: what the app asks for to show the closest results of a refused query.
  public var withoutNothingFound: FindConfig {
    var c = self
    c.nothingFound = NothingFoundTest()
    return c
  }
}
