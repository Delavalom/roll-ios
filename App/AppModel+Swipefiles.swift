import Commit
import Embedding
import EmbeddingGemma
import Entitlements
import Foundation
import Indexer
import Library
import ModelInstall
import Monitor
import Observation
import Overview
import Ranking
import Signals
import Squish
import SquishBridge
import Store
import SwiftUI
import Synchronization
import os

extension AppModel {
  // MARK: - Swipefiles

  /// The deck for a swipefile: the engine once the model is attached; before that the signal deck for the presets it
  /// serves (Screenshots, Blurry, Big videos); nil for embedding-ranked piles while the model isn't ready.
  func deck(for swipefile: SwipefileRecord) -> (any SwipeDeck)? {
    if let engine { return engine }
    return SignalDeck.supports(swipefile) ? SignalDeck(repositories: repositories) : nil
  }

  /// The first `limit` cards of a preset swipefile (empty while its deck needs the model).
  func previewCards(for preset: Preset, limit: Int) async throws -> [String] {
    try await ensurePresetSwipefiles()
    let swipefile = preset.swipefile(created: 0)
    guard let deck = deck(for: swipefile) else { return [] }
    return try await deck.candidates(for: swipefile, limit: limit, excluding: []).map(\.id)
  }

  /// Saves a new custom swipefile (validated by `SwipefileEngine.customRecord`). It ranks once the model is attached.
  @discardableResult
  func createSwipefile(name: String, prompts: [String], examples: [String], action: SwipefileAction,
                       albumName: String?) async throws -> SwipefileRecord {
    if let engine {
      return try await engine.createCustom(name: name, prompts: prompts, examples: examples, action: action,
                                           albumName: albumName)
    }
    let record = try SwipefileEngine.customRecord(name: name, prompts: prompts, examples: examples, action: action,
                                                  albumName: albumName, created: Date().timeIntervalSince1970)
    try await repositories.save(record)
    return record
  }

  /// Applies plans to the photo library; squishes go through `ReplaceFlow` (needs full Photos access).
  func makeCommitter(keep4K: Bool = false, allowNetwork: Bool = false) -> PhotoKitCommitter {
    let squish = makeSquishRunner(keep4K: keep4K, allowNetwork: allowNetwork)
    #if DEBUG
    // Device QA: every delete and album move is re-checked against the QA album (or refused on a read-only run).
    if let qa = QARuntime.shared { return PhotoKitCommitter(database: database, pro: entitlements, squish: squish, qaGate: qa.gate) }
    #endif
    return PhotoKitCommitter(database: database, pro: entitlements, squish: squish)
  }

  func makeSquishRunner(keep4K: Bool = false, allowNetwork: Bool = false) -> ReplaceFlowRunner {
    let background = UIKitBackgroundExecution()
    var flow = ReplaceFlow(journal: repositories, allowNetwork: allowNetwork, background: background)
    #if DEBUG
    if let qa = QARuntime.shared {
      flow = qa.squishFlow(journal: repositories, allowNetwork: allowNetwork, background: background) ?? flow
      return qa.scoped(ReplaceFlowRunner(flow: flow, keep4K: keep4K, registry: squishRegistry))
    }
    #endif
    return ReplaceFlowRunner(flow: flow, keep4K: keep4K, registry: squishRegistry)
  }

  // MARK: - Squish recovery

  /// Settles the squish journal (a crash or kill mid-squish, or a declined or failed squish prompt): Home's banner
  /// lists what's left. Needs full access; in limited mode it only counts the open squishes so Home can ask for it.
  func reconcileSquishes() async {
    guard environment.isLive else { return }
    guard access == .full else {
      squishRecovery = SquishRecovery()
      openSquishesNeedingFullAccess = (try? await repositories.openJournalAssetIDs().count) ?? 0
      return
    }
    openSquishesNeedingFullAccess = 0
    if let found = try? await makeSquishRunner().reconcile() {
      squishRecovery = found
      if found.pending.isEmpty { squishRecoveryBlockedByQuota = 0 }
    }
  }

  /// Deletes the originals of verified copies left from an interrupted squish (one system prompt), settling any
  /// decision still queued for them. Without Pro, `retrySquishDeletes` finishes only as many as the free quota has
  /// left; the rest stay pending and Home offers Pro or "Remove copies".
  func finishPendingSquishes() async {
    let pending = squishRecovery.pending
    guard !pending.isEmpty else { return }
    do {
      let outcome = try await makeCommitter().retrySquishDeletes(pending, of: try await queuedPlan())
      let report = switch outcome { case .applied(let r), .cancelled(let r): r }
      squishRecoveryBlockedByQuota = report.squishBlockedByQuota.count
    } catch {
      squishMessage = "The originals couldn't be removed. Try again later."
    }
    await reconcileSquishes()
    bumpLibrary()
  }

  /// Removes the verified copies of an interrupted squish instead of finishing it (one system prompt). Their originals
  /// stay as they are.
  func discardPendingSquishes() async {
    let copies = squishRecovery.pending.map(\.newAssetID)
    guard !copies.isEmpty else { return }
    do {
      try await makeSquishRunner().discardCopies(copies)
      squishRecoveryBlockedByQuota = 0
    } catch {
      squishMessage = "The copies couldn't be removed. Try again later."
    }
    await reconcileSquishes()
    bumpLibrary()
  }

  /// Removes copies an interrupted squish never verified (one system prompt). Their originals were never touched.
  func discardSquishOrphans() async {
    let orphans = squishRecovery.orphanCopyIDs
    guard !orphans.isEmpty else { return }
    do {
      try await makeSquishRunner().discardCopies(orphans)
      squishRecovery.orphanCopyIDs = []
    } catch {
      squishMessage = "The leftover copies couldn't be removed. Try again later."
    }
    bumpLibrary()
  }

  /// Every queued decision, planned as Pro. The plan only supplies which decisions each squish settles: the free quota
  /// is enforced by `PhotoKitCommitter.retrySquishDeletes` itself (Pro or `FreeQuota.remaining()`).
  private func queuedPlan() async throws -> CommitPlan {
    var queued: [DecisionRecord] = []
    var swipefiles: [String: SwipefileRecord] = [:]
    for swipefile in try await repositories.swipefiles() {
      swipefiles[swipefile.id] = swipefile
      queued += try await repositories.queued(for: swipefile.id)
    }
    let records = try await repositories.assets(ids: Array(Set(queued.map(\.assetId))))
    return CommitPlanner.plan(queued: queued, records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                              swipefiles: swipefiles, isPro: true, quotaRemaining: .max)
  }

  var quota: FreeQuota { FreeQuota(database) }

  /// Stores a record for every preset that doesn't have one yet (ids `preset.<rawValue>`).
  func ensurePresetSwipefiles() async throws {
    let existing = Set(try await repositories.swipefiles().map(\.id))
    let now = Date().timeIntervalSince1970
    for (offset, preset) in Preset.allCases.enumerated() {
      let record = preset.swipefile(created: now + Double(offset) / 1000)
      if !existing.contains(record.id) { try await repositories.save(record) }
    }
  }
}
