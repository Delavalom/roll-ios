import Foundation
import Ranking

/// An answer's search (`SwipefileEngine.find` with `FindConfig.shipping`), "more like these" picking, and the
/// "Make album" grids opened from answers and sections.
extension AskModel {
  struct FindOutcome: Sendable {
    /// What swiping deals.
    var swipe: PhotoSearch.Result
    var answer: FindAnswer
  }

  /// Searches with the shipping config. When the query is refused ("nothing clearly matched"), searches once more
  /// without the refusal for the closest few, which the answer shows as such and swiping deals. The status line then
  /// reports both searches' measured time.
  nonisolated static func find(_ query: String, seeds: [String], refinement: PhotoSearch.Refinement,
                               engine: SwipefileEngine) async throws -> FindOutcome {
    var config = FindConfig.shipping
    #if DEBUG
    // UI tests with the stub embedder: its cosines never clear the refusal, so `-UITestNoRefusal` turns it off to show
    // a found answer (sections, Make album from a section).
    if ProcessInfo.processInfo.arguments.contains("-UITestNoRefusal") { config = config.withoutNothingFound }
    #endif
    let result = try await engine.find(query, config: config, seeds: seeds, refinement: refinement)
    guard result.nothingFound else {
      return FindOutcome(swipe: result.photoSearch, answer: FindAnswer(result: result))
    }
    let open = try await engine.find(query, config: config.withoutNothingFound, seeds: seeds, refinement: refinement)
    let answer = FindAnswer(result: result, closest: open)
    var closest = FindSearch.Result()
    let byId = Dictionary((open.matches + open.weaker).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    closest.matches = answer.closest.compactMap { byId[$0] }
    closest.totalBytes = closest.matches.reduce(0) { $0 + $1.estBytes }
    closest.favorites = closest.matches.filter(\.asset.isFavorite).count
    closest.compared = result.compared
    closest.elapsed = result.elapsed + open.elapsed
    return FindOutcome(swipe: closest.photoSearch, answer: answer)
  }

  // MARK: Showing more

  func toggleWeaker(_ answerId: Int) {
    update(answerId) { $0.showsWeaker.toggle() }
  }

  // MARK: More like these

  func startPicking(_ answerId: Int) {
    pick = SeedPick()
    picking = answerId
  }

  func cancelPicking() {
    picking = nil
    pick = SeedPick()
  }

  func togglePick(_ id: String) { pick.toggle(id) }

  func searchPicked() {
    guard pick.canSearch else { return }
    reask(seeds: pick.ids)
  }

  // MARK: Make album

  /// A "Make album" grid for the whole answer: strong matches selected, weaker ones (or the closest results) offered.
  func albumDraft(for answer: Answer) -> Int? {
    guard let find = answer.find else { return nil }
    let ids = find.nothingFound ? find.closest : find.strong + find.weaker
    guard !ids.isEmpty else { return nil }
    return store(AlbumDraft(ids: ids, preselected: find.strong, name: AlbumSelection.defaultName(query: answer.query),
                            query: answer.query, seeds: answer.seeds))
  }

  /// A "Make album" grid for one event section: its matches selected, the rest of the event offered. A finished event
  /// isn't kept updated (a saved query would keep adding photos from other days), so it carries no query.
  func albumDraft(for answer: Answer, section: FindAnswer.Section) -> Int {
    let named = !section.albumName.isEmpty
    return store(AlbumDraft(ids: section.ids + section.rest, preselected: section.ids,
                            name: named ? section.albumName : AlbumSelection.defaultName(query: answer.query),
                            query: named ? nil : answer.query, seeds: answer.seeds))
  }

  /// Keeps `draft` for the `.album` route and returns its id (also for living albums' offers from Home).
  func store(_ draft: AlbumDraft) -> Int {
    let id = makeId()
    albumDrafts[id] = draft
    return id
  }
}
