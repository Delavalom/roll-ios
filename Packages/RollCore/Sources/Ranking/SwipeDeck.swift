import Foundation
import Store

/// What swipe review needs: cards, swipes, undo and the "looks done" hint. `SwipefileEngine` is the full deck
/// (embeddings, learning); `SignalDeck` serves the signal-ranked presets while the model isn't available.
public protocol SwipeDeck: Sendable {
  func candidates(for swipefile: SwipefileRecord, limit: Int, excluding: Set<String>) async throws
    -> [SwipefileEngine.Candidate]
  /// Returns whether a classifier was trained.
  @discardableResult
  func record(swipefileId: String, assetId: String, verdict: Verdict) async throws -> Bool
  func undo(swipefileId: String, assetId: String) async throws
  func isLikelyExhausted(swipefileId: String) async throws -> Bool
}

extension SwipefileEngine: SwipeDeck {}

/// Swipe review on signals alone, for when the model isn't loaded ("search unavailable"). Only presets whose
/// candidates come from a signal filter are served: Screenshots (the screenshot subtype, largest first), Blurry
/// (blurry photos only, blurriest first, by the preset's boost) and Big videos (largest first, as the engine ranks
/// them). Swipes are stored exactly as the engine stores them, so once the model loads they count toward training.
public struct SignalDeck: SwipeDeck {
  public enum DeckError: Error, Equatable {
    /// The swipefile is ranked by embeddings; it needs the model.
    case needsModel
  }

  private static let presets: Set<Preset> = [.screenshots, .blurry, .bigVideos]

  private let repositories: Repositories
  private let now: @Sendable () -> Double

  public init(repositories: Repositories, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
    self.repositories = repositories
    self.now = now
  }

  public static func supports(_ swipefile: SwipefileRecord) -> Bool {
    Preset(swipefile: swipefile).map(presets.contains) ?? false
  }

  public func candidates(for swipefile: SwipefileRecord, limit: Int, excluding: Set<String>) async throws
    -> [SwipefileEngine.Candidate] {
    guard let stored = try await repositories.swipefile(id: swipefile.id) else {
      throw SwipefileEngine.EngineError.unknownSwipefile(swipefile.id)
    }
    guard let preset = Preset(swipefile: stored), Self.presets.contains(preset) else { throw DeckError.needsModel }
    guard limit > 0 else { return [] }
    let pool = try await repositories.rankingCandidates(swipefileId: stored.id, embeddedOnly: false, filter: preset.filter)
    let ranked = pool.filter { !excluding.contains($0.id) }.map { asset in
      SwipefileEngine.Candidate(id: asset.id, score: preset == .blurry ? preset.signalBoost(asset) : Float(asset.estBytes),
                                estBytes: asset.estBytes, mediaType: asset.mediaType)
    }
    return ranked
      .sorted { ($0.score, $0.estBytes, $1.id) > ($1.score, $1.estBytes, $0.id) }
      .prefix(limit)
      .map { $0 }
  }

  @discardableResult
  public func record(swipefileId: String, assetId: String, verdict: Verdict) async throws -> Bool {
    let decision = DecisionRecord(swipefileId: swipefileId, assetId: assetId, verdict: verdict, decidedAt: now())
    guard try await repositories.recordSwipe(decision) != nil else {
      throw SwipefileEngine.EngineError.unknownSwipefile(swipefileId)
    }
    return false
  }

  public func undo(swipefileId: String, assetId: String) async throws {
    try await repositories.undoSwipe(swipefileId: swipefileId, assetId: assetId,
                                     retrainEvery: SwipefileEngine.retrainEvery)
  }

  public func isLikelyExhausted(swipefileId: String) async throws -> Bool {
    let recent = try await repositories.recentVerdicts(swipefileId: swipefileId,
                                                       limit: SwipefileEngine.exhaustionWindow)
    return recent.count == SwipefileEngine.exhaustionWindow && recent.allSatisfy { $0 == .keep }
  }
}
