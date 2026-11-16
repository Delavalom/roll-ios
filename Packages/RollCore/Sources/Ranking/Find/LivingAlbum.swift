import Foundation
import Store

/// Saved searches as living albums: a saved query (`SavedSearchRecord`) re-run later offers only the photos that are
/// new since it was last seen, minus what its pile already decided and what the pile's classifier rejects. Pure; the
/// engine gathers the inputs (`SwipefileEngine.newMatches(for:)`).
///
/// **New** means asset rowid > the watermark (`SavedSearchRecord.lastSeenRowid`): rowids only grow as photos are
/// added, so it needs no clock. **The next watermark** stops before the first photo not embedded yet, so a photo that
/// arrives before its vector is offered on a later run instead of being skipped forever, and it never moves back.
public enum LivingAlbum {
  /// A pile's classifier must give a new match at least this probability. 0.5 is the classifier's own "keep" line
  /// (`SwipefileEngine.lowConfidenceBelow`): a living album should add what the user would keep, not what they'd swipe
  /// away again.
  public static let minimumProbability: Float = 0.5

  public struct Offer: Sendable, Equatable {
    /// New matches to offer, in the answer's order (strong matches only: weaker ones would fill the album with noise).
    public var ids: [String]
    /// What to store with `Repositories.markSavedSearchRun` once the offer is shown.
    public var watermark: Int64
  }

  /// - Parameters:
  ///   - since: the watermark; `saved.lastSeenRowid` when nil.
  ///   - result: the saved query's answer now (`FindSearch.rank` / `SwipefileEngine.find`).
  ///   - rowids: asset id → rowid for (at least) the answer's photos.
  ///   - probabilities: asset id → the pile's classifier probability; nil when the pile has no usable classifier (then
  ///     nothing is filtered by it). A photo missing from a non-nil map is left out (no vector to judge).
  ///   - decided: photos already decided in the pile.
  ///   - maxRowid: the library's highest rowid; `firstUnembedded`: the first rowid after `since` not embedded yet.
  public static func newMatches(saved: SavedSearchRecord, since: Int64? = nil, result: FindSearch.Result,
                                rowids: [String: Int64], probabilities: [String: Float]?, decided: Set<String>,
                                maxRowid: Int64, firstUnembedded: Int64?,
                                minimumProbability: Float = minimumProbability) -> Offer {
    let mark = since ?? saved.lastSeenRowid
    let ids = result.nothingFound ? [] : result.matches.map(\.id).filter { id in
      guard let rowid = rowids[id], rowid > mark, !decided.contains(id) else { return false }
      guard let probabilities else { return true }
      return (probabilities[id] ?? -1) >= minimumProbability
    }
    let ceiling = firstUnembedded.map { min(maxRowid, $0 - 1) } ?? maxRowid
    return Offer(ids: ids, watermark: max(mark, ceiling))
  }
}
