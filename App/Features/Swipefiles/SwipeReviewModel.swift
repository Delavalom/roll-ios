import Foundation
import Library
import Observation
import Overview
import Ranking
import Store

/// A swipefile's card stack (spec §5): 20 cards at a time, refilled before it runs out, with unlimited undo inside
/// the session and a running "N queued · about X GB".
///
/// The user decides only on what they can see: a card whose photo can't be shown (only in iCloud with no local preview
/// and no Wi-Fi, or still downloading with nothing on screen) can only be skipped (`CardGate.skipOnly`). A skip records
/// nothing, so nothing is deleted, kept or learned from it, and the card stays out of this session's refills; it comes
/// back in a later session. `SwipeVerdict.resolve` decides every swipe and Skip (tested in RollCore).
@Observable @MainActor
final class SwipeReviewModel {
  enum State: Equatable {
    case loading
    case ready
    /// The pile ranks by embeddings and the model isn't attached.
    case needsModel
    case failed
  }

  static let batch = 20
  static let refillBelow = 5

  let swipefile: SwipefileRecord
  private(set) var state: State = .loading
  /// Top card first.
  private(set) var cards: [SwipefileEngine.Candidate] = [] {
    didSet { images.show(cards.map(\.id)) }
  }
  /// The images of the top cards (prefetched, cancelled when swiped away).
  let images: CardImages
  private(set) var queued = CategoryTotal.zero
  private(set) var looksDone = false
  private(set) var canUndo = false
  /// This session's swipes, oldest first (undo takes the last one off): the learning sticker reads them.
  private(set) var verdicts: [Verdict] = []
  /// The last change was an undo (until the next swipe).
  private(set) var justUndid = false
  /// Shown in an alert.
  var message: String?

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var history: [(card: SwipefileEngine.Candidate, verdict: Verdict)] = []
  @ObservationIgnored private var refilling = false
  @ObservationIgnored private var exhausted = false
  /// Cards skipped because they couldn't be shown: kept out of this session's refills.
  @ObservationIgnored private var skipped: Set<String> = []
  /// Swipes are stored in order, one after another.
  @ObservationIgnored private var pending: Task<Void, Never>?

  /// A fixed deck (a search answer, `SearchDeck`) replaces the swipefile's own.
  @ObservationIgnored private let fixedDeck: (any SwipeDeck)?

  init(app: AppModel, swipefile: SwipefileRecord, deck: (any SwipeDeck)? = nil) {
    self.app = app
    self.swipefile = swipefile
    fixedDeck = deck
    images = CardImages(source: app.thumbnails)
  }

  func image(for card: SwipefileEngine.Candidate) -> CardImage { images.state(for: card.id) }

  /// What a swipe on the top card may do right now.
  var topGate: CardGate { cards.first.map { image(for: $0).gate } ?? .wait }

  /// What a left swipe does, for labels.
  var actionTitle: String {
    switch swipefile.action {
    case .delete: "Delete"
    case .album: "Add to album"
    case .squish: "Squish"
    }
  }

  var queuedText: String {
    queued.bytes > 0 ? "\(queued.count.formatted()) queued · \(ByteFormat.about(queued.bytes))" : "\(queued.count.formatted()) queued"
  }

  private var deck: (any SwipeDeck)? { fixedDeck ?? app.deck(for: swipefile) }

  /// Whether swipes here train the pile: the engine is attached and the pile ranks by its photos (not by size, and
  /// not on the signal deck). Training itself starts once the pile has enough decisions (`SwipefileEngine`).
  var learns: Bool {
    guard let deck, !(deck is SignalDeck) else { return false }
    return Preset(swipefile: swipefile)?.ranksByBytes != true
  }

  /// "7 of the last 8 on target": of the last `window` swipes, how many went to the pile (action or album).
  func onTarget(window: Int = 10) -> (hits: Int, of: Int) {
    let recent = verdicts.suffix(window)
    return (recent.filter { $0 != .keep }.count, recent.count)
  }

  func load() async {
    guard let deck else {
      state = .needsModel
      await refreshQueued()
      return
    }
    do {
      cards = try await deck.candidates(for: swipefile, limit: Self.batch, excluding: [])
      exhausted = cards.count < Self.batch
      looksDone = try await deck.isLikelyExhausted(swipefileId: swipefile.id)
      state = .ready
    } catch {
      state = .failed
    }
    await refreshQueued()
  }

  /// Swipes the top card: it leaves the stack at once, and the decision is stored right after. Left is the pile's
  /// action, right keeps, up adds to an album.
  func swipe(_ verdict: Verdict) {
    guard deck != nil, !cards.isEmpty else { return }
    switch SwipeVerdict.resolve(gate: topGate, requested: verdict) {
    case .record(let verdict):
      let card = cards.removeFirst()
      let previous = pending
      pending = Task {
        await previous?.value
        await record(card, verdict)
      }
    case .skip: skipTop()
    case .ignore: return
    }
  }

  /// Moves past a card that can't be shown, without a decision.
  func skip() {
    guard !cards.isEmpty, SwipeVerdict<Verdict>.resolve(gate: topGate, requested: nil) == .skip else { return }
    skipTop()
  }

  private func skipTop() {
    skipped.insert(cards.removeFirst().id)
    let previous = pending
    pending = Task {
      await previous?.value
      await refillIfNeeded()
    }
  }

  /// The screen went away (or full screen covers it): stop loading card images; `appeared()` starts them again.
  func disappeared() { images.cancelAll() }
  func appeared() {
    images.show(cards.map(\.id))
    images.retryUnavailable()
  }

  /// While the screen is up: joining Wi-Fi loads the cards that couldn't be shown again.
  func watchWiFi() async { await images.watchWiFi() }

  private func record(_ card: SwipefileEngine.Candidate, _ verdict: Verdict) async {
    guard let deck else { return }
    do {
      try await deck.record(swipefileId: swipefile.id, assetId: card.id, verdict: verdict)
      history.append((card, verdict))
      verdicts.append(verdict)
      justUndid = false
      canUndo = true
      looksDone = try await deck.isLikelyExhausted(swipefileId: swipefile.id)
    } catch {
      cards.insert(card, at: 0)
      message = "That swipe couldn't be saved."
    }
    await refreshQueued()
    await refillIfNeeded()
  }

  func undo() async {
    await pending?.value
    guard let deck, let last = history.popLast() else { return }
    canUndo = !history.isEmpty
    // Taken off with the history entry, so a swipe landing during the await can't shift which verdict goes.
    let undone = verdicts.popLast()
    do {
      try await deck.undo(swipefileId: swipefile.id, assetId: last.card.id)
      cards.removeAll { $0.id == last.card.id }
      cards.insert(last.card, at: 0)
      justUndid = true
      looksDone = try await deck.isLikelyExhausted(swipefileId: swipefile.id)
    } catch {
      history.append(last)
      if let undone { verdicts.append(undone) }
      canUndo = true
      message = "That swipe couldn't be undone."
    }
    await refreshQueued()
  }

  /// Waits for the swipes still being stored, so Review & apply plans the whole queue.
  func flush() async { await pending?.value }

  /// After the commit sheet: applied decisions leave the queue, deleted assets leave the stack, and undo history ends
  /// here: an applied change can't be taken back (anything not applied stays queued).
  func committed() async {
    await pending?.value
    history.removeAll()
    canUndo = false
    await refreshQueued()
    let records = (try? await app.repositories.assets(ids: cards.map(\.id))) ?? []
    let live = Set(records.filter { !$0.deleted }.map(\.id))
    cards.removeAll { !live.contains($0.id) }
    await refillIfNeeded()
  }

  private func refillIfNeeded() async {
    guard let deck, !refilling, !exhausted, cards.count < Self.refillBelow else { return }
    refilling = true
    defer { refilling = false }
    let showing = Set(cards.map(\.id))
    if let more = try? await deck.candidates(for: swipefile, limit: Self.batch, excluding: showing.union(skipped)) {
      // Showing when the refill started or now (a swipe may land while it runs).
      let fresh = SwipeRefill.fresh(more, showing: showing.union(cards.map(\.id)), skipped: skipped)
      cards += fresh
      exhausted = fresh.isEmpty
    }
  }

  private func refreshQueued() async {
    guard let decisions = try? await app.repositories.queued(for: swipefile.id),
          let records = try? await app.repositories.assets(ids: decisions.map(\.assetId)) else { return }
    let live = records.filter { !$0.deleted }
    queued = CategoryTotal(count: live.count, bytes: live.reduce(0) { $0 + $1.estBytes })
  }
}
