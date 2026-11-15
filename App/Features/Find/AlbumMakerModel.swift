import Commit
import Foundation
import Observation
import Ranking
import Store

/// "Make album": the selection grid's state, then Create through the commit path every change uses: the selection is
/// queued under the album's hidden queue (`AlbumQueue`), planned by `CommitPlanner` (same free-quota rule, see
/// `FreeQuota.countsAlbumAdds`) and applied by `PhotoKitCommitter` via `CommitModel`.
@Observable @MainActor
final class AlbumMakerModel {
  enum Phase: Equatable {
    case editing
    case working
    /// Some of the selection is past the free quota: `allowed` can still be added now.
    case quota(blocked: Int, allowed: Int)
    /// `added` photos went into `album` (0: they were all in it already).
    case created(album: String, added: Int)
    case failed(String)
  }

  let draft: AlbumDraft
  var selection: AlbumSelection
  private(set) var phase: Phase = .editing
  private(set) var progressText: String?
  /// What Create added, for "Make a video".
  private(set) var added: [String] = []
  private(set) var keepUpdated: KeepUpdatedOffer = .unavailable
  private(set) var savingKeep = false

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var commit: CommitModel?
  @ObservationIgnored private var queueId: String?

  init(app: AppModel, draft: AlbumDraft) {
    self.app = app
    self.draft = draft
    selection = AlbumSelection(ids: draft.ids, preselected: draft.preselected, name: draft.name)
  }

  /// A living album's offer adds to its own album: the name can't change.
  var isOffer: Bool { draft.savedSearchId != nil }

  var isBusy: Bool { phase == .working }

  func create() async {
    guard selection.canCreate, !isBusy else { return }
    phase = .working
    let album = selection.trimmedName
    do {
      let id = try await AlbumQueue.replace(album: album, with: selection.orderedSelection,
                                            repositories: app.repositories)
      queueId = id
      let commit = CommitModel(app: app, swipefileIds: [id])
      self.commit = commit
      await commit.load()
      if case .failed(let text) = commit.phase { phase = .failed(text); return }
      let plan = commit.plan
      if plan.blockedByQuota > 0 {
        phase = .quota(blocked: plan.blockedByQuota, allowed: plan.albumMoves.values.reduce(0) { $0 + $1.count })
        return
      }
      if plan.isEmpty {
        await finished(album: album, added: [])
        return
      }
      await apply()
    } catch {
      phase = .failed("The album couldn't be set up. Nothing was changed.")
    }
  }

  /// Adds what the plan allows (all of it, or the free part after a quota notice).
  func apply() async {
    guard let commit else { return }
    let album = selection.trimmedName
    guard !commit.plan.isEmpty else { phase = .editing; return }
    phase = .working
    progressText = "Adding to \(album)…"
    await commit.apply()
    progressText = nil
    switch commit.phase {
    case .done(let report):
      await finished(album: album, added: report.addedToAlbums.values.flatMap { $0 })
    case .cancelled:
      phase = .editing
    case .stopped, .failed:
      phase = .failed("Photos couldn't add them to the album. Nothing else was changed.")
    default:
      phase = .editing
    }
  }

  /// Back from the paywall: plan again (Pro lifts the limit).
  func recheck() async {
    guard case .quota = phase else { return }
    phase = .editing
    await create()
  }

  func backToEditing() { phase = .editing }

  private func finished(album: String, added: [String]) async {
    self.added = added
    phase = .created(album: album, added: added.count)
    if let saved = draft.savedSearchId {
      let chosen = Set(selection.orderedSelection)
      await app.living.resolve(saved, passed: draft.ids.filter { !chosen.contains($0) })
      keepUpdated = .alreadyKept
    } else {
      keepUpdated = KeepUpdatedOffer.state(query: draft.query, seeds: draft.seeds, albumName: album,
                                           saved: await app.living.savedSearches())
    }
  }

  /// "Keep this album updated": a saved search for the query, adding nothing now.
  func keepAlbumUpdated() async {
    guard keepUpdated == .available, let query = draft.query, case .created(let album, _) = phase else { return }
    savingKeep = true
    defer { savingKeep = false }
    do {
      try await app.living.keep(query: query, albumName: album,
                                queueId: queueId ?? AlbumQueue.swipefileId(album: album))
      keepUpdated = .alreadyKept
    } catch {
      progressText = "That couldn't be saved. Try again."
    }
  }

  /// "Not now" on a living album's offer: nothing is added, and these photos aren't offered again.
  func dismissOffer() async {
    guard let saved = draft.savedSearchId else { return }
    await app.living.resolve(saved)
  }
}
