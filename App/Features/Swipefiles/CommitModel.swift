import Commit
import Foundation
import Observation
import Overview
import Squish
import SquishBridge
import Store

/// The commit sheet's model: builds the `CommitPlanner` plan for some swipefiles' queues, then applies it with
/// `PhotoKitCommitter` (iOS shows its own confirmation for every delete). Squishes run through `ReplaceFlow`.
@Observable @MainActor
final class CommitModel {
  enum Phase: Equatable {
    case loading
    case ready
    case applying
    case done(CommitReport)
    /// The user declined a system prompt. Nothing more was applied or spent; verified squish copies may be waiting.
    case cancelled(CommitReport)
    /// A change failed partway (not a user decline). The report holds what was applied before it; `reason` is why.
    case stopped(CommitReport, SquishRefusal)
    case failed(String)
  }

  /// A squish that didn't happen, with why.
  struct Refusal: Identifiable, Equatable {
    let assetID: String
    let reason: SquishRefusal
    var id: String { assetID }
  }

  let swipefileIds: [String]
  let keep4K: Bool
  let allowNetwork: Bool
  private(set) var phase: Phase = .loading
  private(set) var plan = CommitPlan()
  private(set) var progressText: String?

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var committer: PhotoKitCommitter?
  @ObservationIgnored private var squishSeen: [String] = []

  init(app: AppModel, swipefileIds: [String], keep4K: Bool = false, allowNetwork: Bool = false) {
    self.app = app
    self.swipefileIds = swipefileIds
    self.keep4K = keep4K
    self.allowNetwork = allowNetwork
  }

  var isPro: Bool { app.entitlements.isPro }

  /// Squish needs full Photos access; with limited access the squishes would all be refused.
  var squishNeedsFullAccess: Bool { !plan.squishes.isEmpty && app.access != .full }

  /// What the confirm sheet must say squish can't carry over (includes the iCloud Shared Library line).
  var transferLimitations: [String] { SquishLimitations.items }

  /// About how much the squishes save, from the planner's estimates.
  var estimatedSquishSavings: Int64 {
    let catalog = SquishPlanner.plan(records: plannedRecords, keep4K: keep4K, videoFacts: plannedFacts)
    let ids = Set(plan.squishes.map(\.assetID))
    return catalog.filter { ids.contains($0.assetID) }.reduce(0) { $0 + $1.estimatedSavings }
  }

  @ObservationIgnored private var plannedRecords: [AssetRecord] = []
  /// What the format probe measured, so an already compact video adds no savings here either.
  @ObservationIgnored private var plannedFacts: [String: VideoProbeFacts] = [:]

  var canApply: Bool { phase == .ready && (!plan.isEmpty || !plan.stale.isEmpty) && !blockedByAccessOnly }

  /// Only squishes are queued and they can't run without full access.
  private var blockedByAccessOnly: Bool {
    squishNeedsFullAccess && plan.deletes.isEmpty && plan.albumMoves.isEmpty && plan.stale.isEmpty
  }

  var applyTitle: String {
    if !plan.deletes.isEmpty {
      return "Delete \(plan.deletes.count.formatted()) \(plan.deletes.count == 1 ? "item" : "items")"
    }
    if !plan.squishes.isEmpty, plan.albumMoves.isEmpty {
      return "Squish \(plan.squishes.count.formatted()) \(plan.squishes.count == 1 ? "item" : "items")"
    }
    return "Apply"
  }

  func load() async {
    phase = .loading
    do {
      let repositories = app.repositories
      var queued: [DecisionRecord] = []
      var swipefiles: [String: SwipefileRecord] = [:]
      for id in swipefileIds {
        guard let swipefile = try await repositories.swipefile(id: id) else { continue }
        swipefiles[id] = swipefile
        queued += try await repositories.queued(for: id)
      }
      let records = try await repositories.assets(ids: Array(Set(queued.map(\.assetId))))
      plannedRecords = records
      plannedFacts = try await repositories.videoProbeFacts()
      let pro = app.entitlements.isPro
      let remaining = pro ? Int.max : try await app.quota.remaining()
      // Never delete every shot of a duplicate group (its keeper swiped away in another pile, say).
      var keeping = Set<String>()
      for kind in [DuplicateGroup.Kind.duplicates, .similarShots] {
        keeping.formUnion(try await repositories.queued(for: DuplicateReview.swipefileId(for: kind)).map(\.assetId))
      }
      let protected = DuplicateReview.protectedGroups(app.home.summary.groups, queued: keeping)
      plan = CommitPlanner.plan(queued: queued, records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                                swipefiles: swipefiles, isPro: pro, quotaRemaining: remaining, protecting: protected)
      phase = .ready
    } catch {
      phase = .failed("Your queue couldn't load.")
    }
  }

  func apply() async {
    guard canApply else { return }
    phase = .applying
    let committer = app.makeCommitter(keep4K: keep4K, allowNetwork: allowNetwork)
    self.committer = committer
    await run { [plan] progress in try await committer.apply(plan, progress: progress) }
  }

  /// The report shown after a run (done, cancelled or stopped).
  var report: CommitReport? {
    switch phase {
    case .done(let r), .cancelled(let r), .stopped(let r, _): r
    default: nil
    }
  }

  /// Whether the queue survives closing the sheet. The Squish screen empties `__squish__` when its sheet closes.
  var keepsQueue: Bool { swipefileIds != [SquishQueue.swipefileId] }

  /// Planned deletes that didn't happen because the run stopped.
  var deletesNotApplied: Int {
    guard case .stopped(let report, _) = phase else { return 0 }
    return max(0, plan.deletes.count - report.deleted.count)
  }

  /// After a declined squish prompt or a failure: ask again to delete the originals of the verified copies.
  func retrySquishDeletes() async {
    guard let report, phase != .applying, let committer, !report.pendingSquishCopies.isEmpty else { return }
    phase = .applying
    let pending = report.pendingSquishCopies
    await run { [plan] _ in try await committer.retrySquishDeletes(pending, of: plan) }
  }

  /// Removes squish copies the user doesn't want (a declined prompt) or that failed verification.
  func discardCopies(_ ids: [String]) async {
    guard !ids.isEmpty else { return }
    let committer = committer ?? app.makeCommitter()
    do {
      try await committer.discardCopies(ids)
      switch phase {
      case .cancelled(var report):
        report.pendingSquishCopies.removeAll { ids.contains($0.newAssetID) }
        report.leftoverCopyIDs.removeAll { ids.contains($0) }
        phase = .cancelled(report)
      case .done(var report):
        report.leftoverCopyIDs.removeAll { ids.contains($0) }
        report.pendingSquishCopies.removeAll { ids.contains($0.newAssetID) }
        report.squishSkipped.removeAll { ids.contains($0.newAssetID) }
        phase = .done(report)
      case .stopped(var report, let reason):
        report.leftoverCopyIDs.removeAll { ids.contains($0) }
        report.pendingSquishCopies.removeAll { ids.contains($0.newAssetID) }
        report.squishSkipped.removeAll { ids.contains($0.newAssetID) }
        phase = .stopped(report, reason)
      default: break
      }
    } catch {
      progressText = "The copies couldn't be removed."
    }
    app.bumpLibrary()
  }

  private func run(_ body: (@escaping @Sendable (CommitProgress) -> Void) async throws -> CommitOutcome) async {
    squishSeen = []
    let progress: @Sendable (CommitProgress) -> Void = { [weak self] update in
      Task { @MainActor in self?.show(update) }
    }
    do {
      switch try await body(progress) {
      case .applied(let report): phase = .done(report)
      case .cancelled(let report): phase = .cancelled(report)
      }
    } catch let failure as CommitFailure {
      phase = .stopped(failure.report, Self.reason(for: failure.underlying))
    } catch {
      phase = .failed("Photos couldn't make the change.")
    }
    progressText = nil
    app.bumpLibrary()
  }

  /// Why a run stopped, in the squish refusal's terms (needs Full Access, not enough space, ...). Failures that aren't
  /// squish-specific read as Photos refusing the change.
  static func reason(for error: any Error) -> SquishRefusal {
    switch SquishRefusal.classify(error) {
    case .failed("Something went wrong."): .failed("Photos couldn't make the change.")
    case let other: other
    }
  }

  /// The sheet closed. Squish copies that are still waiting (a declined or failed prompt, a skipped original) move to
  /// Home's recovery banner, which re-reads them from the journal.
  func closed() {
    guard let report, !report.pendingSquishCopies.isEmpty || !report.squishSkipped.isEmpty
      || !report.squishUnregistered.isEmpty || !report.leftoverCopyIDs.isEmpty || !plan.squishes.isEmpty else { return }
    let app = app
    Task { await app.reconcileSquishes() }
  }

  /// Squishes that didn't happen, classified for the UI.
  static func refusals(in report: CommitReport) -> [Refusal] {
    report.squishFailures.map { Refusal(assetID: $0.assetID, reason: SquishRefusal.classify($0.error)) }
  }

  private func show(_ progress: CommitProgress) {
    guard phase == .applying else { return }
    switch progress {
    case .deleting(let done, let total): progressText = "Deleting \(done) of \(total)…"
    case .addingToAlbum(let name): progressText = "Adding to \(name)…"
    case .squishing(let step):
      if !squishSeen.contains(step.assetID) { squishSeen.append(step.assetID) }
      let stage = switch step.stage {
      case .downloading: "downloading from iCloud"
      case .encoding: "encoding"
      case .verifying: "checking the copy"
      case .saving: "saving"
      }
      progressText = "Squishing \(squishSeen.count) of \(plan.squishes.count) · \(stage)…"
    case .deletingSquishedOriginals(let count): progressText = "Replacing \(count) originals…"
    }
  }
}
