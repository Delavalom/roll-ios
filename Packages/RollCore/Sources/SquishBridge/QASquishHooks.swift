#if DEBUG
import Squish

/// DEBUG-only device QA observers for `ReplaceFlowRunner.qaScoped` (see docs/qa/). Release builds compile none of this.
/// The app turns these into identifier-free metrics lines; nothing here may change what the flow does except
/// `beforeCommitDeletes`, which may wait (a manual QA step: change an original between prepare and commit).
public struct QASquishHooks: Sendable {
  /// After `prepare`, with the full report (verified fingerprints, failures).
  public var prepared: (@Sendable (PrepareReport) -> Void)?
  /// Right before the delete prompt for this many originals. May suspend; the QA gate runs after it returns.
  public var beforeCommitDeletes: (@Sendable (Int) async -> Void)?
  /// After the delete change (or the user declining it).
  public var committed: (@Sendable (Result<SquishCommitResult, ReplaceError>) -> Void)?

  public init(prepared: (@Sendable (PrepareReport) -> Void)? = nil,
              beforeCommitDeletes: (@Sendable (Int) async -> Void)? = nil,
              committed: (@Sendable (Result<SquishCommitResult, ReplaceError>) -> Void)? = nil) {
    self.prepared = prepared; self.beforeCommitDeletes = beforeCommitDeletes; self.committed = committed
  }
}
#endif
