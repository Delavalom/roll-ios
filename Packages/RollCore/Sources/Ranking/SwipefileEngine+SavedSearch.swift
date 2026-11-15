import Foundation
import Store

// MARK: - Saved searches (living albums)

extension SwipefileEngine {
  /// What saved search `id` would add now (`LivingAlbum.newMatches`): its query re-run with `config`, new photos only,
  /// minus its pile's decisions and what the pile's classifier rejects. Doesn't move the watermark: store
  /// `Offer.watermark` with `Repositories.markSavedSearchRun` once the offer is shown. Nil for an unknown id.
  public func newMatches(for id: String, config: FindConfig = .default) async throws -> LivingAlbum.Offer? {
    guard let saved = try await repositories.savedSearch(id: id) else { return nil }
    let result = try await find(saved.query, config: config)
    let ids = result.matches.map(\.id)
    let rowids = try await repositories.assetRowids(ids: ids)
    var probabilities: [String: Float]? = nil
    var decided = Set<String>()
    if let pileId = saved.swipefileId, let pile = try await repositories.swipefile(id: pileId) {
      decided = Set(try await repositories.decidedAssetIds(swipefileId: pileId))
      if let model = usableClassifier(pile) {
        var probs: [String: Float] = [:]
        for id in ids where !decided.contains(id) && (rowids[id] ?? 0) > saved.lastSeenRowid {
          if let v = await vectors.vector(for: id) { probs[id] = model.prob(v) }
        }
        probabilities = probs
      }
    }
    return LivingAlbum.newMatches(
      saved: saved, result: result, rowids: rowids, probabilities: probabilities, decided: decided,
      maxRowid: try await repositories.maxAssetRowid(),
      firstUnembedded: try await repositories.firstUnembeddedRowid(after: saved.lastSeenRowid))
  }
}
