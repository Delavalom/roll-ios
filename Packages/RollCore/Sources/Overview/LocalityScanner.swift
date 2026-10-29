import Foundation
import Library
import Store

/// Whether an asset's original resource is on this iPhone, asked with network access off (never downloads).
public protocol LocalityChecking: Sendable {
  /// true: on the device; false: only in iCloud; nil: no answer (missing, cancelled).
  func isLocal(_ record: AssetRecord) async -> Bool?
}

/// Checks where the originals of cleanup candidates are (`CleanupSummary.localityCandidates`, plus Squish's), so
/// "You can free about X on this iPhone" counts only originals that are on the device. Not-yet-checked items go first,
/// largest first; then known ones are re-checked, largest first (iOS offloads originals over time); at most `budget`
/// per scan. Keep one scanner for the launch: an item it tried (answered or not) isn't tried again for `recheckAfter`,
/// so repeated scans only check what's new. Each check gets `timeout`: one that doesn't answer counts as not checked
/// (the stored locality stays; unknown counts as iCloud), and after `maxConsecutiveTimeouts` in a row the scan stops
/// (PhotoKit isn't answering). Run it at utility priority.
public actor LocalityScanner {
  public struct Result: Sendable, Equatable {
    public var checked: Int
    public var local: Int
    public var iCloud: Int
    /// No answer, including `timedOut`.
    public var unanswered: Int
    public var timedOut: Int
    public init(checked: Int, local: Int, iCloud: Int, unanswered: Int, timedOut: Int = 0) {
      self.checked = checked; self.local = local; self.iCloud = iCloud; self.unanswered = unanswered
      self.timedOut = timedOut
    }
  }

  public static let defaultBudget = 2_000
  public static let defaultRecheckAfter: Duration = .seconds(3_600)
  /// A local original answers with its first chunk and an iCloud-only one fails at once, both in milliseconds.
  public static let defaultTimeout: Duration = .seconds(5)
  public static let maxConsecutiveTimeouts = 3

  private let repositories: Repositories
  private let checker: any LocalityChecking
  private let budget: Int
  private let recheckAfter: Duration
  private let timeout: Duration
  /// When each item was last tried by this scanner.
  private var tried: [String: ContinuousClock.Instant] = [:]

  public init(repositories: Repositories, checker: any LocalityChecking, budget: Int = LocalityScanner.defaultBudget,
              recheckAfter: Duration = LocalityScanner.defaultRecheckAfter,
              timeout: Duration = LocalityScanner.defaultTimeout) {
    self.repositories = repositories; self.checker = checker; self.budget = budget
    self.recheckAfter = recheckAfter; self.timeout = timeout
  }

  public func scan(_ candidateIDs: [String]) async throws -> Result {
    let now = ContinuousClock.now
    let records = try await repositories.assets(ids: Array(Set(candidateIDs)))
      .filter { record in tried[record.id].map { now - $0 >= recheckAfter } ?? true }
    func largestFirst(_ a: AssetRecord, _ b: AssetRecord) -> Bool { (a.estBytes, b.id) > (b.estBytes, a.id) }
    let ordered = records.filter { $0.originalLocal == nil }.sorted(by: largestFirst)
      + records.filter { $0.originalLocal != nil }.sorted(by: largestFirst)
    var local: [String] = [], iCloud: [String] = [], unanswered = 0, checked = 0, timedOut = 0, inARow = 0
    let checker = checker
    for record in ordered.prefix(budget) {
      try Task.checkCancellation()
      let answer = await Deadline.answer(within: timeout) { await checker.isLocal(record) }
      try Task.checkCancellation()  // a cancelled scan gives up its last check: not tried
      checked += 1
      tried[record.id] = .now
      guard let answer else {
        unanswered += 1
        timedOut += 1
        inARow += 1
        if inARow >= Self.maxConsecutiveTimeouts { break }
        continue
      }
      inARow = 0
      switch answer {
      case true?: local.append(record.id)
      case false?: iCloud.append(record.id)
      case nil: unanswered += 1
      }
    }
    try await repositories.setOriginalLocal(local, local: true)
    try await repositories.setOriginalLocal(iCloud, local: false)
    return Result(checked: checked, local: local.count, iCloud: iCloud.count, unanswered: unanswered,
                  timedOut: timedOut)
  }
}
