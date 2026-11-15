import Foundation

extension FindConfig {
  /// **What the app ships**: Ask Roll answers, "more like these" and living albums all search with this one value,
  /// so tuning it here (from the find eval, ADR-0006) changes every Find surface at once. `default` (V0) stays what
  /// `SwipefileEngine.search` and the eval's baseline use.
  ///
  /// Starting point, 2026-11-15 (to be replaced by the eval's numbers):
  /// - `relativeCut` 0.6: the eval's best F1 (P .54, R .58, median 130 photos instead of ~940).
  /// - `nothingFound.minTopCosine` 0.735: a first guess for refusing queries nothing in the library answers; the
  ///   app then shows "Nothing clearly matched" with the closest few.
  /// - Understanding (dates and places filter), events (support bonus, sections, "rest of this event") on.
  public static var shipping: FindConfig {
    var c = FindConfig.v0
    c.relativeCut = 0.6
    c.nothingFound = NothingFoundTest(minTopCosine: 0.735)
    c.understanding = true
    c.events = true
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
