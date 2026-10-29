import Foundation
import Observation
import Overview
import Store

/// The groups of one kind (exact duplicates or similar shots) and what's already queued from them.
@Observable @MainActor
final class DuplicatesModel {
  let kind: DuplicateGroup.Kind
  private(set) var queued: Set<String> = []
  var message: String?

  @ObservationIgnored private let app: AppModel

  init(app: AppModel, kind: DuplicateGroup.Kind) {
    self.app = app
    self.kind = kind
  }

  var title: String { kind == .duplicates ? "Duplicates" : "Similar shots" }

  /// From Home's summary, so the list follows index batches and commits.
  var groups: [DuplicateGroup] { app.home.summary.groups(kind) }

  var queuedCount: Int { queued.count }

  /// This kind's hidden queue (`__duplicates__` or `__similar__`), applied from this screen only.
  var swipefileId: String { DuplicateReview.swipefileId(for: kind) }

  func keeper(of group: DuplicateGroup) -> String { DuplicateReview.keeper(of: group, queued: queued) }
  func isQueued(_ group: DuplicateGroup) -> Bool { DuplicateReview.isQueued(group, queued: queued) }

  func load() async {
    queued = Set(((try? await app.repositories.queued(for: swipefileId)) ?? []).map(\.assetId))
  }

  /// "Delete N others": queues everyone but `keeper`.
  func deleteOthers(in group: DuplicateGroup, keeping keeper: String) async {
    do {
      try await DuplicateReview.queue(group, keeper: keeper, repositories: app.repositories)
    } catch {
      message = "That group couldn't be queued."
    }
    await load()
    app.bumpLibrary()
  }

  func keepAll(in group: DuplicateGroup) async {
    try? await DuplicateReview.unqueue(group, repositories: app.repositories)
    await load()
    app.bumpLibrary()
  }

  func bytes(of ids: [String]) async -> Int64 {
    ((try? await app.repositories.assets(ids: ids)) ?? []).reduce(0) { $0 + $1.estBytes }
  }
}
