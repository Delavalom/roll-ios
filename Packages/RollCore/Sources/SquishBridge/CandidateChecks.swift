import Foundation
import Overview
import Store

/// The checks that follow indexing: where the cleanup candidates' originals are (`LocalityScanner`), then the formats
/// of local big videos (`SquishFormatScreen`). The app runs them once its type lookups have drained, outside the
/// indexing task (a PhotoKit request that never answers can't hold indexing up; both checks time out), and again when
/// a later indexing loop drains. Keep one for the launch: the scanner and the screen remember what they checked, so a
/// repeat round only checks what's new.
///
/// One round at a time. A call made during a round returns nil and folds into one more round after it, with the
/// latest candidates; the running caller gets the outcome of both.
public actor CandidateChecks {
  public struct Outcome: Sendable, Equatable {
    /// Distinct ids the locality check was given.
    public var candidates = 0
    public var locality = LocalityScanner.Result(checked: 0, local: 0, iCloud: 0, unanswered: 0)
    public var formats = SquishFormatScreen.Screening()
    public var rounds = 0
    public var elapsed: Duration = .zero

    public init() {}

    /// Whether the Store changed (Home's numbers and Squish's list should refresh).
    public var changed: Bool { locality.local + locality.iCloud + formats.recorded > 0 }

    mutating func add(_ other: Outcome) {
      candidates = max(candidates, other.candidates)
      locality.checked += other.locality.checked
      locality.local += other.locality.local
      locality.iCloud += other.locality.iCloud
      locality.unanswered += other.locality.unanswered
      locality.timedOut += other.locality.timedOut
      formats.refused += other.formats.refused
      formats.recorded += other.formats.recorded
      formats.timedOut += other.formats.timedOut
      rounds += other.rounds
      elapsed += other.elapsed
    }
  }

  private let repositories: Repositories
  private let locality: LocalityScanner
  private let formats: SquishFormatScreen
  private var running = false
  /// A call made during a round: its candidates (`.some(nil)`: compute them).
  private var queued: [String]??

  public init(repositories: Repositories, locality: LocalityScanner, formats: SquishFormatScreen) {
    self.repositories = repositories
    self.locality = locality
    self.formats = formats
  }

  /// `homeCandidates`: Home's latest `CleanupSummary.localityCandidates` (reusing its duplicate groups); nil when Home
  /// hasn't scanned yet, then they're computed with a full `CleanupScanner.scan()`. Squish's items are added either
  /// way. Returns nil when folded into the running round.
  public func run(homeCandidates: [String]?) async -> Outcome? {
    guard !running else {
      queued = .some(homeCandidates)
      return nil
    }
    running = true
    defer { running = false }
    var total = Outcome()
    var next: [String]?? = .some(homeCandidates)
    while case .some(let candidates) = next {
      next = nil
      total.add(await round(candidates))
      next = queued  // calls made during the round
      queued = nil
    }
    return total
  }

  private func round(_ homeCandidates: [String]?) async -> Outcome {
    let start = ContinuousClock.now
    var outcome = Outcome()
    outcome.rounds = 1
    let catalog = try? await SquishCatalog.load(repositories: repositories, keep4K: false)
    var ids: [String]
    if let homeCandidates {
      ids = homeCandidates
    } else {
      ids = (try? await CleanupScanner(repositories: repositories).scan().localityCandidates) ?? []
    }
    ids += catalog?.items.map(\.assetID) ?? []
    outcome.candidates = Set(ids).count
    if let result = try? await locality.scan(ids) { outcome.locality = result }
    // Videos found on this iPhone just now are probed in this round too: the catalog is reloaded then.
    let screened = outcome.locality.local > 0 ? nil : catalog
    if let screening = try? await formats.screen(catalog: screened) { outcome.formats = screening }
    outcome.elapsed = ContinuousClock.now - start
    return outcome
  }
}
