import Commit
import Foundation
import Observation
import Ranking
import Store

/// Living albums (`SavedSearchRecord`): after indexing drains, the event pass regroups the library, then each saved
/// search is asked for photos added since it last ran (`SwipefileEngine.newMatches` with `FindConfig.shipping`).
/// Offers wait in `inbox` ("12 new photos for Soccer" on Home) until the person reviews them; nothing is added
/// silently. Acting on an offer (adding some, or "Not now") stores its watermark so the same photos aren't offered
/// again, and photos left out are passed over in the album's queue.
///
/// The saved search keeps the query and album, not a config: it re-runs with whatever `FindConfig.shipping` is at the
/// time, so tuning Find improves living albums too.
@Observable @MainActor
final class LivingAlbumsModel {
  private(set) var inbox = LivingAlbumInbox()
  /// The last event pass's result (DEBUG overlay and QA only).
  private(set) var lastEvents: EventPass.Outcome?

  @ObservationIgnored private let repositories: Repositories
  @ObservationIgnored private let events: EventPass
  @ObservationIgnored private var running = false

  init(repositories: Repositories) {
    self.repositories = repositories
    events = EventPass(repositories: repositories)
  }

  /// Events, then every saved search's new photos. A call while one runs is dropped (the next drain asks again).
  func refresh(engine: SwipefileEngine?) async {
    guard !running else { return }
    running = true
    defer { running = false }
    if let outcome = try? await events.run() { lastEvents = outcome }
    guard let engine else { return }
    let saved = (try? await repositories.savedSearches()) ?? []
    inbox.keep(only: Set(saved.map(\.id)))
    for search in saved {
      guard let offer = try? await engine.newMatches(for: search.id, config: .shipping) else { continue }
      inbox.receive(offer, for: search)
    }
  }

  /// "Keep this album updated": remembers the query for the album, from the photos the library holds now on.
  func keep(query: String, albumName: String, queueId: String) async throws {
    let now = Date().timeIntervalSince1970
    let record = SavedSearchRecord(query: query, albumName: albumName, swipefileId: queueId, createdAt: now,
                                   lastRunAt: now, lastSeenRowid: try await repositories.maxAssetRowid())
    try await repositories.save(record)
  }

  func savedSearches() async -> [SavedSearchRecord] { (try? await repositories.savedSearches()) ?? [] }

  /// The person acted on an offer: it leaves the inbox, its watermark is stored, and `passed` (offered photos they
  /// left out) won't be offered for this album again.
  func resolve(_ savedSearchId: String, passed: [String] = []) async {
    guard let item = inbox.resolve(savedSearchId) else { return }
    if !passed.isEmpty { try? await AlbumQueue.pass(album: item.albumName, ids: passed, repositories: repositories) }
    try? await repositories.markSavedSearchRun(id: savedSearchId, lastSeenRowid: item.watermark,
                                               at: Date().timeIntervalSince1970)
  }

  /// The review grid for an offer: every new photo selected (the person can still leave any out).
  func draft(for savedSearchId: String) -> AlbumDraft? {
    guard let item = inbox.item(savedSearchId) else { return nil }
    return AlbumDraft(ids: item.ids, preselected: item.ids, name: item.albumName, query: item.query,
                      savedSearchId: savedSearchId)
  }
}
