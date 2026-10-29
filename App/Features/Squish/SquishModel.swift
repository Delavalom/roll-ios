import Commit
import Foundation
import Observation
import Squish
import SquishBridge
import Store

/// Squish (spec §8): candidates sorted by size, the Keep 4K and iCloud-download choices, and the items refused for
/// their format. "Squish N items" queues the selection under `__squish__` and hands it to the commit sheet, so quota,
/// Store bookkeeping and the one system prompt work like every other change.
@Observable @MainActor
final class SquishModel {
  private(set) var catalog = SquishCatalog()
  private(set) var isLoading = true
  var selected: Set<String> = []
  var keep4K = false {
    didSet { if keep4K != oldValue { Task { await load() } } }
  }
  var allowICloudDownloads = false
  /// Shown in an alert with its own title.
  var notice: SquishNotice?

  @ObservationIgnored private let app: AppModel
  /// Items the user ticked or unticked: their choice stays over later default selections.
  @ObservationIgnored private var userChoices: Set<String> = []
  @ObservationIgnored private var probing: Task<Void, Never>?

  init(app: AppModel) { self.app = app }

  var needsFullAccess: Bool { app.access != .full }

  /// What the run will attempt: an iCloud item counts only while downloads are allowed (its tick is kept, so turning
  /// downloads back on brings it back).
  var selectedItems: [SquishPlanItem] { catalog.runnable(selected, downloadsAllowed: allowICloudDownloads) }

  /// An original only in iCloud can't be picked while downloads are off; its row says so.
  func canSelect(_ id: String) -> Bool { catalog.canSquish(id, downloadsAllowed: allowICloudDownloads) }

  func isSelected(_ id: String) -> Bool { canSelect(id) && selected.contains(id) }

  var selectedSavings: Int64 { selectedItems.reduce(0) { $0 + $1.estimatedSavings } }

  /// Refused for their format up front, or by an earlier squish (remembered in the Store until the item changes).
  var notSquishable: [NotSquishable] { catalog.notSquishable }

  var squishTitle: String {
    "Squish \(selectedItems.count.formatted()) \(selectedItems.count == 1 ? "item" : "items")"
  }

  /// Shows the list right away, then reads local videos' formats in the background (one task) and refreshes: a video
  /// starts selected only once its format passed, and a Dolby Vision one leaves the list.
  func load() async {
    await refresh()
    guard probing == nil else { return }
    probing = Task { [weak self] in
      guard let self else { return }
      await self.app.screenSquishFormats()
      await self.refresh()
      self.probing = nil
    }
  }

  private func refresh() async {
    do {
      let fresh = try await SquishCatalog.load(repositories: app.repositories, keep4K: keep4K)
      // Items on this iPhone start selected (photos at once, videos after their probe); iCloud ones need a download,
      // so the user opts in. Whatever the user ticked or unticked stays.
      let ids = Set(fresh.items.map(\.assetID))
      #if DEBUG
      let defaults = QARuntime.shared?.squishStartsEmpty == true ? [] : fresh.defaultSelection
      #else
      let defaults = fresh.defaultSelection
      #endif
      selected = selected.intersection(ids).union(defaults.filter { !userChoices.contains($0) })
      catalog = fresh
    } catch {
      notice = .couldntLoad
    }
    isLoading = false
  }

  func toggle(_ id: String) {
    guard canSelect(id) else { return }
    userChoices.insert(id)
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
  }

  /// Queues the selection (largest first) and returns the commit model for the confirm sheet.
  func prepareRun() async -> CommitModel? {
    // Without Wi-Fi nothing downloads, so iCloud items drop out here too: the sheet shows what the run attempts.
    let onWiFi = allowICloudDownloads ? await WiFi.isAvailable() : false
    let ids: [String], network: Bool
    switch catalog.start(selected, downloadsAllowed: allowICloudDownloads, onWiFi: onWiFi) {
    case .run(let runIds, let allowNetwork): (ids, network) = (runIds, allowNetwork)
    case .blocked(let why):
      notice = why
      return nil
    case .nothing: return nil
    }
    do {
      try await SquishQueue.replace(with: ids, repositories: app.repositories)
    } catch {
      notice = .couldntQueue
      return nil
    }
    return CommitModel(app: app, swipefileIds: [SquishQueue.swipefileId], keep4K: keep4K, allowNetwork: network)
  }

  /// After the sheet closes: remember what was refused (in the Store, so it isn't offered again until the item
  /// changes), clear what's left in the queue, refresh. Copies still waiting next to their originals move to Home's
  /// recovery banner (`CommitModel.closed()`), and their originals aren't offered here until that's settled.
  func finished(_ run: CommitModel) async {
    if let report = run.report {
      for refusal in CommitModel.refusals(in: report) {
        guard case .notSquishable(let why) = refusal.reason else { continue }
        try? await app.repositories.recordSquishRefusal(assetId: refusal.assetID, reason: why)
      }
    }
    try? await SquishQueue.replace(with: [], repositories: app.repositories)
    await load()
  }
}
