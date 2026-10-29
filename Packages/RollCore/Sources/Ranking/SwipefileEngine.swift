import Embedding
import Foundation
import Store

/// Picks the next cards for a swipefile and learns from the swipes (spec §5).
///
/// **Candidates.** Every live asset that passes the preset's filter (`CandidateFilter.matches`) and has no decision
/// yet in this swipefile. The rows live in memory (`CandidatePool`: re-read from SQL only after a write that changes
/// what ranking reads); decisions are read per call. Embedding swipefiles score the whole index in one
/// `VectorStore.dotAll` matrix product (the prompts plus the mean example vector, or the classifier weights once
/// trained), and the pool is aligned with its rows as integers (`poolScores`, `PoolScores`); only ids the index scored
/// are candidates. Then `Scorer`'s formulas. Big videos skip embeddings and rank by `estBytes`.
///
/// Untrained piles put each query on its own scale (`QueryScale`): an asset is dealt only if it stands out,
/// z >= `QueryScale.zGate`, for some prompt (or the mean example), and cards under `Fold.defaultRatio` x the pile's
/// best z are flagged `lowConfidence`. A fixed cosine floor filtered nothing with this model: its cosines average
/// 0.58-0.66 (pile eval, `docs/investigations/2026-10-29-pile-eval.md`). Trained piles are **rank-based**: the top `limit`
/// of the eligible pool by score, dropping only probabilities under 0.05 and flagging those under
/// 0.5 `lowConfidence`. An absolute 0.5 floor dead-ended piles where the user mostly keeps: only
/// `record` retrains, so an empty pile never recovered. `isLikelyExhausted` tells the UI when the
/// user's own swipes say the pile looks done.
///
/// **Learning.** `record` stores the swipe and bumps `swipesSinceTrain` in one transaction, then
/// (re)trains a logistic classifier when the swipefile has at least 8 decided assets with vectors,
/// at least 2 positives (action / album: both mean "belongs in this pile") and 2 negatives (keep),
/// and either no usable classifier yet or at least 5 swipes since the last training (an undo on a
/// trained pile makes the next swipe retrain). The prompt vectors join as positives with
/// weight 2, and the weights are class-balanced (each class totals 0.5), so a pile of mostly
/// "keep" swipes still ranks its positives first. The result is persisted on the swipefile.
///
/// Prompt vectors are cached per embedder revision, swipefile id and prompt list, for the life of
/// the engine. The embedder must have the index's revision and width (`EngineError`).
public actor SwipefileEngine {
  public struct Candidate: Sendable, Equatable, Identifiable {
    public var id: String
    /// `Scorer` score; for big videos, the estimated bytes.
    public var score: Float
    public var estBytes: Int64
    public var mediaType: Int
    /// A weaker match the UI can fold away: for trained swipefiles the classifier rates it below
    /// `lowConfidenceBelow` (still dealt: retrieval is rank-based); for untrained ones its z is under
    /// `Fold.defaultRatio` x the pile's best.
    public var lowConfidence: Bool = false
  }

  public enum EngineError: Error, Equatable {
    case unknownSwipefile(String)
    case dimensionMismatch(embedder: Int, index: Int)
    /// The embedder's model revision differs from the one the index was built with, so prompt
    /// vectors and stored vectors are not comparable.
    case revisionMismatch
    /// A custom swipefile needs at least one non-blank prompt or one example to rank by.
    case emptySwipefile
  }

  /// Trained: only near-certain non-matches (classifier probability below this) are dropped.
  public static let trainedProbabilityFloor: Float = 0.05
  /// Trained: a card whose probability is below this is flagged `lowConfidence`.
  public static let lowConfidenceBelow: Float = 0.5
  public static let minDecisionsToTrain = 8
  public static let minPerLabel = 2
  public static let retrainEvery = 5
  public static let promptWeight: Float = 2
  /// `isLikelyExhausted` looks at this many most recent swipes.
  public static let exhaustionWindow = 10

  let repositories: Repositories
  let vectors: VectorStore
  let embedder: any Embedder
  let now: @Sendable () -> Double
  /// Asset id -> share of a typed query's words found in its text (`Repositories.keywordCoverage`); nil without a
  /// keyword index. Only `search` uses it.
  let keywordCoverage: LibrarySearch.KeywordCoverage?
  private var promptCache: [PromptKey: (prompts: [String], vectors: [[Float]])] = [:]
  /// Swipefiles with a retrain in flight. The actor is reentrant at every `await`, so without
  /// this a swipe arriving mid-training would start a second, overlapping one.
  private var training: Set<String> = []
  /// The live rows in memory between searches (see `CandidatePool`).
  let candidatePool: CandidatePool

  private struct PromptKey: Hashable {
    var revision: String
    var swipefileId: String
  }

  public init(repositories: Repositories, vectors: VectorStore, embedder: any Embedder,
              keywordCoverage: LibrarySearch.KeywordCoverage? = nil,
              now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
    self.keywordCoverage = keywordCoverage
    self.repositories = repositories
    self.vectors = vectors
    self.embedder = embedder
    self.now = now
    self.candidatePool = CandidatePool(repositories: repositories)
  }

  // MARK: - Custom swipefiles

  /// Validates and saves a new custom swipefile. Prompts are trimmed and blank ones dropped;
  /// throws `emptySwipefile` (saving nothing) if no prompt and no example is left.
  public func createCustom(id: String = UUID().uuidString, name: String, prompts: [String], examples: [String],
                           action: SwipefileAction, albumName: String? = nil) async throws -> SwipefileRecord {
    let record = try Self.customRecord(id: id, name: name, prompts: prompts, examples: examples, action: action,
                                       albumName: albumName, created: now())
    try await repositories.save(record)
    return record
  }

  /// The validation `createCustom` applies, without saving: prompts trimmed and blank ones dropped; throws
  /// `emptySwipefile` if no prompt and no example is left. The app uses it to create a pile before the model
  /// has loaded (it ranks once the model is attached).
  public static func customRecord(id: String = UUID().uuidString, name: String, prompts: [String],
                                  examples: [String], action: SwipefileAction, albumName: String? = nil,
                                  created: Double) throws -> SwipefileRecord {
    let prompts = prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !prompts.isEmpty || !examples.isEmpty else { throw EngineError.emptySwipefile }
    return SwipefileRecord(id: id, name: name, kind: .custom, prompts: prompts, examples: examples, action: action,
                           albumName: albumName, created: created)
  }

  // MARK: - Candidates

  /// The best `limit` undecided candidates, best first (ties by id), skipping `excluding` (the UI
  /// passes the cards already on screen, so a refill fetched while a swipe is being recorded
  /// can't deal them twice). Always reads the stored copy of `swipefile`, so a classifier trained
  /// since the caller loaded it is used; throws `unknownSwipefile` if it was deleted.
  public func candidates(for swipefile: SwipefileRecord, limit: Int = 20,
                         excluding: Set<String> = []) async throws -> [Candidate] {
    try await timedCandidates(for: swipefile, limit: limit, excluding: excluding).cards
  }

  /// `candidates`, plus how long each step took (benchmarks and the DEBUG QA search bench).
  public func timedCandidates(for swipefile: SwipefileRecord, limit: Int = 20,
                              excluding: Set<String> = []) async throws -> (cards: [Candidate], timings: SearchTimings) {
    let clock = ContinuousClock()
    let begin = clock.now
    var t = SearchTimings()
    func done(_ cards: [Candidate]) -> (cards: [Candidate], timings: SearchTimings) {
      t.total = clock.now - begin
      return (cards, t)
    }
    guard limit > 0 else { return done([]) }
    guard let swipefile = try await repositories.swipefile(id: swipefile.id) else {
      throw EngineError.unknownSwipefile(swipefile.id)
    }
    t.lookup = clock.now - begin
    let preset = Preset(swipefile: swipefile)
    let filter = preset?.filter ?? .none

    if preset?.ranksByBytes == true {
      let (snapshot, read) = try await candidatePool.snapshot()
      t.sql = read
      var mark = clock.now
      let decided = Set(try await repositories.decidedAssetIds(swipefileId: swipefile.id))
      t.decisions = clock.now - mark
      mark = clock.now
      let videos = snapshot.rows.compactMap { row -> Candidate? in
        let a = row.asset
        guard filter.matches(a), !decided.contains(a.id), !excluding.contains(a.id) else { return nil }
        return Candidate(id: a.id, score: Float(a.estBytes), estBytes: a.estBytes, mediaType: a.mediaType)
      }
      t.poolCount = videos.count
      let top = Self.top(videos, limit: limit)
      t.score = clock.now - mark
      return done(top)
    }

    // Trained: the classifier's weights are the one query. Untrained: the prompts, plus the mean example vector
    // (vectors are unit, so the mean of dots with the examples is one dot with their mean).
    var mark = clock.now
    let model = usableClassifier(swipefile)
    var queries: [[Float]] = []
    if let model {
      queries = [model.w]
    } else {
      let prompts = try await promptVectors(for: swipefile)
      let center = await meanExampleVector(swipefile.examples)
      queries = prompts + (center.map { [$0] } ?? [])
    }
    t.queries = clock.now - mark
    guard !queries.isEmpty else { return done([]) }

    let pool = try await poolScores(queries: queries, preset: preset, filter: filter, decidedIn: swipefile.id,
                                    excluding: excluding)
    t.sql = pool.timings.sql
    t.decisions = pool.timings.decisions
    t.dot = pool.timings.dot
    t.pool = pool.timings.pool
    t.poolCount = pool.timings.poolCount

    mark = clock.now
    var cards: [Candidate] = []
    if let model {
      let dots = pool.dots(query: 0)
      var scores = [Float](repeating: -.infinity, count: pool.count)
      for k in 0..<pool.count {
        let p = LogisticClassifier.sigmoid(dots[k] + model.b)
        if p >= Self.trainedProbabilityFloor { scores[k] = Scorer.trained(probability: p, boost: pool.boosts[k]) }
      }
      for k in pool.top(scores, limit: limit, minimum: -.greatestFiniteMagnitude) {
        var card = Self.card(pool, k, scores[k])
        card.lowConfidence = LogisticClassifier.sigmoid(dots[k] + model.b) < Self.lowConfidenceBelow
        cards.append(card)
      }
    } else {
      // Each query on its own scale; only assets that stand out (z >= zGate) are dealt, and those under
      // `Fold.defaultRatio` x the pile's best are flagged `lowConfidence` (shown as weaker matches).
      let scores = pool.untrainedZ(queryCount: queries.count)
      let topZ = scores.max() ?? 0  // over the whole pool, decided cards too, so a card's label doesn't shift
      cards = pool.top(scores, limit: limit, minimum: QueryScale.zGate).map { k in
        var card = Self.card(pool, k, scores[k])
        card.lowConfidence = Fold.isWeak(scores[k], top: topZ)
        return card
      }
    }
    t.score = clock.now - mark
    return done(cards)
  }

  private static func card(_ pool: PoolScores, _ k: Int, _ score: Float) -> Candidate {
    let a = pool.asset(k)
    return Candidate(id: a.id, score: score, estBytes: a.estBytes, mediaType: a.mediaType)
  }

  /// The best `limit`, best first (ties by id), without sorting the whole pool.
  static func top(_ candidates: [Candidate], limit: Int) -> [Candidate] {
    func better(_ a: Candidate, _ b: Candidate) -> Bool { a.score != b.score ? a.score > b.score : a.id < b.id }
    guard candidates.count > limit else { return candidates.sorted(by: better) }
    var best: [Candidate] = []
    best.reserveCapacity(limit + 1)
    for c in candidates {
      if best.count == limit, !better(c, best[limit - 1]) { continue }
      let at = best.firstIndex { better(c, $0) } ?? best.count
      best.insert(c, at: at)
      if best.count > limit { best.removeLast() }
    }
    return best
  }

  private func promptVectors(for swipefile: SwipefileRecord) async throws -> [[Float]] {
    // Checked before the cache, so a cached entry can't hide a model switch.
    let revision = embedder.revision
    guard revision == vectors.revision else { throw EngineError.revisionMismatch }
    guard embedder.dimensions == vectors.dimensions else {
      throw EngineError.dimensionMismatch(embedder: embedder.dimensions, index: vectors.dimensions)
    }
    let key = PromptKey(revision: revision, swipefileId: swipefile.id)
    if let cached = promptCache[key], cached.prompts == swipefile.prompts { return cached.vectors }
    var out: [[Float]] = []
    for prompt in swipefile.prompts { out.append(Self.normalized(try await embedder.embed(query: prompt))) }
    promptCache[key] = (swipefile.prompts, out)
    return out
  }

  /// The mean of the (normalized) example vectors; nil if no example has a vector.
  private func meanExampleVector(_ ids: [String]) async -> [Float]? {
    var sum = [Float](repeating: 0, count: vectors.dimensions)
    var n = 0
    for id in ids {
      guard let v = await vectors.vector(for: id) else { continue }
      for (i, x) in Self.normalized(v).enumerated() { sum[i] += x }
      n += 1
    }
    return n > 0 ? sum.map { $0 / Float(n) } : nil
  }

  static func normalized(_ v: [Float]) -> [Float] {
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? v.map { $0 / norm } : v
  }

  // MARK: - Exhaustion

  /// True when the last `exhaustionWindow` swipes in this swipefile were all "keep": the user's
  /// own behavior says the pile looks done, so the UI can offer "Looks done — finish?". It is a
  /// hint only and never hides candidates. False for fewer swipes or an unknown swipefile.
  public func isLikelyExhausted(swipefileId: String) async throws -> Bool {
    let recent = try await repositories.recentVerdicts(swipefileId: swipefileId, limit: Self.exhaustionWindow)
    return recent.count == Self.exhaustionWindow && recent.allSatisfy { $0 == .keep }
  }

  // MARK: - Swipes

  /// Stores the swipe (replacing an earlier one for the asset), then retrains if due.
  /// Returns whether a classifier was trained.
  @discardableResult
  public func record(swipefileId: String, assetId: String, verdict: Verdict) async throws -> Bool {
    let decision = DecisionRecord(swipefileId: swipefileId, assetId: assetId, verdict: verdict, decidedAt: now())
    guard let swipefile = try await repositories.recordSwipe(decision) else {
      throw EngineError.unknownSwipefile(swipefileId)
    }
    return try await retrainIfDue(swipefile)
  }

  /// Removes the decision, so the asset can come back as a candidate. If the swipefile is
  /// trained, the classifier is kept for now but the next `record` retrains it without the undone
  /// decision (see `Repositories.undoSwipe`).
  public func undo(swipefileId: String, assetId: String) async throws {
    try await repositories.undoSwipe(swipefileId: swipefileId, assetId: assetId, retrainEvery: Self.retrainEvery)
  }

  private func retrainIfDue(_ swipefile: SwipefileRecord) async throws -> Bool {
    if Preset(swipefile: swipefile)?.ranksByBytes == true { return false }
    let usable = usableClassifier(swipefile) != nil
    guard !usable || swipefile.swipesSinceTrain >= Self.retrainEvery else { return false }
    // Checked and claimed with no suspension in between, so it is atomic on the actor. A swipe
    // skipped here still counts: the save below only subtracts the swipes this run consumed.
    guard training.insert(swipefile.id).inserted else { return false }
    defer { training.remove(swipefile.id) }

    var x: [[Float]] = [], y: [Float] = []
    for decision in try await repositories.decisions(for: swipefile.id) {
      guard let v = await vectors.vector(for: decision.assetId) else { continue }
      x.append(v)
      // "Album" (swipe up) is a positive like the action: the classifier learns "belongs in this
      // pile", not "should be deleted". What happens to a card is the verdict's business.
      y.append(decision.verdict == .keep ? 0 : 1)
    }
    let positives = y.filter { $0 == 1 }.count
    guard x.count >= Self.minDecisionsToTrain, positives >= Self.minPerLabel,
          x.count - positives >= Self.minPerLabel else { return false }

    var weights = [Float](repeating: 1, count: x.count)
    for prompt in try await promptVectors(for: swipefile) {
      x.append(prompt); y.append(1); weights.append(Self.promptWeight)
    }
    let model = LogisticClassifier.train(x: x, y: y, weights: LogisticClassifier.classBalanced(y: y, weights: weights))
    try await repositories.saveClassifier(swipefileId: swipefile.id, classifier: model.blob, revision: vectors.revision,
                                          consumedSwipes: swipefile.swipesSinceTrain)
    return true
  }

  /// The stored classifier, if it decodes at the index's width and was trained on the index's
  /// revision (weights from another model live in another vector space).
  private func usableClassifier(_ swipefile: SwipefileRecord) -> LogisticClassifier? {
    guard let blob = swipefile.classifier, swipefile.classifierRevision == vectors.revision else { return nil }
    return LogisticClassifier(blob: blob, dimensions: vectors.dimensions)
  }
}
