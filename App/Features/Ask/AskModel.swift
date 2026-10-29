import Commit
import Foundation
import Observation
import Ranking
import Store

/// Ask Roll: describe what to clear, see what matches, narrow it down, swipe through it, apply. One conversation of
/// turns; every number in it comes from the library (`SwipefileEngine.search`, `PhotoSearch`, `SearchSummary`).
/// Nothing is generated: the reply is built from the matches' dates and favorites.
@Observable @MainActor
final class AskModel {
  struct Answer: Identifiable, Equatable {
    let id: Int
    let query: String
    let refinement: PhotoSearch.Refinement
    /// Nil while searching.
    var result: PhotoSearch.Result?
    /// Why the search didn't run.
    var failure: String?
    /// A refinement of the answer before it (titled by what changed).
    var isRefinement: Bool
    /// The grid shows every match, not the first rows.
    var expanded = false
    /// Matches still to swipe in the query's pile (nil until known; no pile yet means all of them).
    var remaining: Int?

    /// What "Swipe through N" deals.
    var toSwipe: Int { remaining ?? result?.matches.count ?? 0 }
  }

  enum Turn: Identifiable, Equatable {
    case asked(id: Int, text: String)
    case answer(Answer)
    /// The answer was saved as a pile.
    case saved(id: Int, name: String)
    /// Review & apply finished: what left the library.
    case done(id: Int, count: Int, bytes: Int64)

    var id: Int {
      switch self {
      case .asked(let id, _), .saved(let id, _), .done(let id, _, _): id
      case .answer(let answer): answer.id
      }
    }
  }

  /// The grid's rows before "+ N more".
  static let previewCount = 9
  static let liveDelay: Duration = .milliseconds(300)

  private(set) var turns: [Turn] = []
  /// The composer's text. Typing searches as you go (`live`).
  var draft = "" {
    didSet { if draft != oldValue { draftChanged() } }
  }
  /// While typing: how many photos match the draft so far, and the first few.
  private(set) var live: (count: Int, ids: [String])?
  private(set) var searching = false
  /// Queries that already have a pile (Save pile then says so).
  private(set) var savedQueries: Set<String> = []

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var liveTask: Task<Void, Never>?
  @ObservationIgnored private var askTask: Task<Void, Never>?
  @ObservationIgnored private var nextId = 0
  /// Piles made from answers, by query, in flight or made: "Swipe through" and "Save pile" share one.
  @ObservationIgnored private var piles: [String: Task<SwipefileRecord, any Error>] = [:]

  init(app: AppModel) {
    self.app = app
  }

  var isChatting: Bool { !turns.isEmpty }
  var canAsk: Bool { app.engine != nil }

  /// The answer the action buttons and chips act on: the last one that came back (a failed search leaves the one
  /// before it in charge, so there is always a way on).
  var actionableAnswer: Answer? {
    for turn in turns.reversed() { if case .answer(let answer) = turn, answer.result != nil { return answer } }
    return nil
  }

  func answer(id: Int) -> Answer? {
    for turn in turns { if case .answer(let answer) = turn, answer.id == id { return answer } }
    return nil
  }

  // MARK: Asking

  func submit() {
    let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, canAsk, !searching else { return }
    draft = ""
    turns.append(.asked(id: makeId(), text: query))
    ask(query, refinement: .init(), isRefinement: false)
  }

  /// Toggles one refinement on the actionable answer, as a new turn.
  func refine(_ change: (inout PhotoSearch.Refinement) -> Void) {
    guard let base = actionableAnswer, !searching else { return }
    var refinement = base.refinement
    change(&refinement)
    ask(base.query, refinement: refinement, isRefinement: true)
  }

  func expand(_ id: Int) {
    update(id) { $0.expanded = true }
  }

  /// Back to the start: a search still running is dropped.
  func startOver() {
    liveTask?.cancel()
    askTask?.cancel()
    askTask = nil
    searching = false
    turns = []
    draft = ""
    live = nil
  }

  /// Appends the answer turn at once (so it always follows its question), then searches.
  private func ask(_ query: String, refinement: PhotoSearch.Refinement, isRefinement: Bool) {
    let id = makeId()
    turns.append(.answer(Answer(id: id, query: query, refinement: refinement, isRefinement: isRefinement)))
    guard let engine = app.engine else {
      update(id) { $0.failure = "The on-device AI isn't ready yet. Try again once it is." }
      return
    }
    searching = true
    askTask = Task { [weak self] in
      let outcome: Result<PhotoSearch.Result, any Error>
      do { outcome = .success(try await engine.search(query, refinement: refinement)) } catch { outcome = .failure(error) }
      guard let self, !Task.isCancelled else { return }
      self.searching = false
      switch outcome {
      case .success(let result):
        self.update(id) { $0.result = result }
        await self.refreshRemaining(id)
      case .failure(let error):
        self.update(id) { $0.failure = Self.failureText(error) }
      }
    }
  }

  private static func failureText(_ error: any Error) -> String {
    switch error as? SwipefileEngine.EngineError {
    case .revisionMismatch?, .dimensionMismatch?:
      "Your library was read with another version of the on-device AI. Search works again once Roll has read it with this one."
    default:
      "That search didn't run. Try again."
    }
  }

  private func draftChanged() {
    liveTask?.cancel()
    let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 3, let engine = app.engine else {
      live = nil
      return
    }
    liveTask = Task { [weak self] in
      try? await Task.sleep(for: Self.liveDelay)
      guard !Task.isCancelled else { return }
      let result = try? await engine.search(query)
      guard !Task.isCancelled else { return }
      self?.live = result.map { ($0.matches.count, $0.matches.prefix(5).map(\.id)) }
    }
  }

  // MARK: Piles

  /// The pile an answer swipes into: a delete pile described by the query alone, made once per query (a pile the
  /// user set up differently, with examples or another action, is never reused).
  func pile(for answer: Answer) async throws -> SwipefileRecord {
    let query = answer.query
    if let task = piles[query], let pile = try? await task.value,
       (try? await app.repositories.swipefile(id: pile.id)) != nil {
      return pile
    }
    let app = app
    let task = Task<SwipefileRecord, any Error> { @MainActor in
      if let existing = try await app.repositories.swipefiles().first(where: {
        $0.kind == .custom && $0.prompts == [query] && $0.examples.isEmpty && $0.action == .delete
      }) {
        return existing
      }
      let made = try await app.createSwipefile(name: Self.name(query), prompts: [query], examples: [], action: .delete,
                                               albumName: nil)
      app.bumpLibrary()
      return made
    }
    piles[query] = task
    do {
      let pile = try await task.value
      savedQueries.insert(query)
      return pile
    } catch {
      piles[query] = nil
      throw error
    }
  }

  func save(_ answer: Answer) async {
    guard let pile = try? await pile(for: answer) else { return }
    turns.append(.saved(id: makeId(), name: pile.name))
  }

  /// Recounts what's left to swipe for every answer whose query has a pile (after a search, and back from swiping).
  func refreshRemaining(_ only: Int? = nil) async {
    let swipefiles = (try? await app.repositories.swipefiles()) ?? []
    for turn in turns {
      guard case .answer(let answer) = turn, only == nil || answer.id == only, let result = answer.result,
            let pile = swipefiles.first(where: {
              $0.kind == .custom && $0.prompts == [answer.query] && $0.examples.isEmpty && $0.action == .delete
            }) else { continue }
      savedQueries.insert(answer.query)
      let open = (try? await app.repositories.undecided(result.matches.map(\.id), in: pile.id))?.count
      update(answer.id) { $0.remaining = open }
    }
  }

  /// Review & apply closed. Deletions become a "cleared" turn, sized from the deleted assets themselves (the pile
  /// may have held more than this answer).
  func applied(_ report: CommitReport?) async {
    guard let report, !report.deleted.isEmpty else { return }
    let records = (try? await app.repositories.assets(ids: report.deleted)) ?? []
    let bytes = records.reduce(0) { $0 + $1.estBytes }
    turns.append(.done(id: makeId(), count: report.deleted.count, bytes: bytes))
    await refreshRemaining()
  }

  // MARK: Copy

  /// "Screenshots of group chats".
  static func name(_ query: String) -> String {
    query.prefix(1).uppercased() + query.dropFirst()
  }

  /// An answer's title: the query for the first, what changed for a refinement ("22 older than a year").
  static func title(_ answer: Answer) -> String {
    guard answer.isRefinement, let result = answer.result else { return name(answer.query) }
    let filters = [answer.refinement.olderThanAYear ? "older than a year" : nil,
                   answer.refinement.onlyOnThisIPhone ? "on this iPhone" : nil].compactMap { $0 }
    // "22 older than a year, biggest first"; without a filter the count takes a noun: "8 matches, biggest first".
    var title = "\(result.matches.count.formatted())"
    title += filters.isEmpty ? " \(result.matches.count == 1 ? "match" : "matches")" : " " + filters.joined(separator: " and ")
    if answer.refinement.biggestFirst { title += ", biggest first" }
    return title
  }

  /// "38 photos · about 214 MB", or for a refinement "about 131 MB · none of them favorites".
  static func subtitle(_ answer: Answer) -> String {
    guard let result = answer.result else { return "" }
    let size = ByteFormat.about(result.totalBytes)
    if answer.isRefinement {
      return "\(size) · \(SearchSummary.favorites(result.favorites, of: result.matches.count))"
    }
    return "\(photos(result.matches.count)) · \(size)"
  }

  /// "+ 29 more · 6 weaker matches folded".
  static func more(_ result: PhotoSearch.Result, showing: Int) -> String? {
    let hidden = max(0, result.matches.count - showing)
    let weaker = result.weaker.count
    var parts: [String] = []
    if hidden > 0 { parts.append("+ \(hidden.formatted()) more") }
    if weaker > 0 { parts.append("\(weaker.formatted()) weaker \(weaker == 1 ? "match" : "matches") folded") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// "Most are from 2023 and early 2024. Want to swipe through them, or narrow it down first?"
  static func reply(_ answer: Answer) -> String {
    guard let result = answer.result, !result.matches.isEmpty else { return "" }
    let when = SearchSummary.when(result.matches.map(\.created)).map { $0 + " " } ?? ""
    let ask = result.matches.count == 1 ? "Want to look at it?" : answer.isRefinement
      ? "Swipe through these?" : "Want to swipe through them, or narrow it down first?"
    return when + ask
  }

  /// "Compared 29,589 items on this iPhone in 0.09 s" (counted and measured by the engine).
  static func elapsed(_ result: PhotoSearch.Result) -> String {
    let seconds = Double(result.elapsed.components.seconds) + Double(result.elapsed.components.attoseconds) / 1e18
    let time = seconds < 0.01 ? "under 0.01 s" : "\(seconds.formatted(.number.precision(.fractionLength(2)))) s"
    let items = "\(result.compared.formatted()) \(result.compared == 1 ? "item" : "items")"
    return "Compared \(items) on this iPhone in \(time)"
  }

  static func photos(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "photo" : "photos")" }

  /// Under the swipe step's title: "older than a year · 22 photos" (what's left to swipe).
  static func swipeSubtitle(_ answer: Answer) -> String {
    let count = answer.remaining == 0 ? "all swiped" : photos(answer.toSwipe)
    let filters = [answer.refinement.olderThanAYear ? "older than a year" : nil,
                   answer.refinement.onlyOnThisIPhone ? "on this iPhone" : nil,
                   answer.refinement.biggestFirst ? "biggest first" : nil].compactMap { $0 }
    return (filters + [count]).joined(separator: " · ")
  }

  // MARK: -

  private func makeId() -> Int {
    nextId += 1
    return nextId
  }

  private func update(_ id: Int, _ change: (inout Answer) -> Void) {
    guard let index = turns.firstIndex(where: { $0.id == id }), case .answer(var answer) = turns[index] else { return }
    change(&answer)
    turns[index] = .answer(answer)
  }
}
