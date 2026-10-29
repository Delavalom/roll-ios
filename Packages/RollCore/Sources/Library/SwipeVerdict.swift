/// What a swipe, a verdict button or Skip does to the top card, by its `CardGate`. The rule: a verdict is recorded
/// only with the photo on screen; a card with nothing on screen can only be skipped; a card still loading does nothing.
/// Generic over the verdict so Library doesn't depend on Store.
public enum SwipeVerdict<Verdict: Sendable & Equatable>: Sendable, Equatable {
  /// Store the verdict (delete, keep or album) and learn from it.
  case record(Verdict)
  /// Move past the card with no decision: nothing stored, and it stays out of this session's refills (`SwipeRefill`).
  case skip
  /// Nothing happens (the card snaps back).
  case ignore

  /// `requested`: the verdict a swipe or button asked for; nil for Skip.
  public static func resolve(gate: CardGate, requested: Verdict?) -> Self {
    switch gate {
    case .decide: requested.map(Self.record) ?? .ignore
    case .skipOnly: .skip
    case .wait: .ignore
    }
  }
}

/// A refill of the card stack after swipes and skips.
public enum SwipeRefill {
  /// The cards of `more` to add: not showing, and not skipped this session.
  public static func fresh<Card: Identifiable>(_ more: [Card], showing: Set<Card.ID>, skipped: Set<Card.ID>) -> [Card] {
    more.filter { !showing.contains($0.id) && !skipped.contains($0.id) }
  }
}
