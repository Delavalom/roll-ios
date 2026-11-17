import Foundation
import Synchronization

/// One holder's claim on setup running (`SetupCoordinator.acquire`).
public struct SetupLease: Sendable, Hashable {
  public let id: UUID
  public let holder: String
}

/// Owns the on-device AI setup's sequence: the model (download, install, prepare), then the library read. The app's
/// runners (in front, iOS 26's continued task, the overnight job) each hold a lease while they want setup to run:
/// the first lease starts a run, later ones join it, and releasing the last one stops it. A run asks `SetupWork` where
/// things stand each time, so whichever runner comes next resumes where the last one stopped.
public actor SetupCoordinator {
  /// Monotonic time and sleep, injectable for tests.
  public struct Clock: Sendable {
    public var now: @Sendable () -> Duration
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
      self.now = now
      self.sleep = sleep
    }

    public static var continuous: Clock {
      let origin = ContinuousClock.now
      return Clock(now: { ContinuousClock.now - origin }, sleep: { try await Task.sleep(for: $0) })
    }
  }

  private struct Run {
    let id: Int
    let task: Task<SetupOutcome, Never>
  }

  private let work: any SetupWork
  private let clock: Clock
  private let tick: Duration
  private var leases: [UUID: String] = [:]
  private var run: Run?
  private var runCount = 0
  private var subscribers: [UUID: AsyncStream<SetupProgress>.Continuation] = [:]
  /// Callers waiting for the run's end (`runHolding` keyed by its lease, `outcome()` by a fresh id), resumed when it
  /// ends or, for a lease, when the lease is released.
  private var waiters: [UUID: CheckedContinuation<SetupOutcome, Never>] = [:]
  /// The run `progress` belongs to: a new run's first value isn't held up by the last run's fraction.
  private var progressRun = 0
  /// The run the last release cancelled: only that one starts again for a holder that came while it wound down.
  private var cancelledRun: Int?

  /// The latest progress, for anyone reading it once.
  public private(set) var progress: SetupProgress = .initial
  /// How the last run ended (nil before any run ends).
  public private(set) var lastOutcome: SetupOutcome?

  /// What the current run last reported and when its step last moved; written from the work's report closures on any
  /// thread, read by `publish` (always the latest, so reports can't arrive out of order).
  /// `reported`: the run has reported at least once; until then nothing is published for it (the stage carried over
  /// from the last run, say `.done` at 1, isn't this run's).
  private let latest = Mutex<(stage: SetupStage, stepStart: Duration, runId: Int, reported: Bool)>(
    (.unknown, .zero, 0, false))

  public init(work: any SetupWork, clock: Clock = .continuous, tick: Duration = .seconds(1)) {
    self.work = work
    self.clock = clock
    self.tick = tick
  }

  // MARK: Leases

  /// Claims setup for `holder` ("foreground", "continued", "overnight"): starts a run unless one is going.
  public func acquire(_ holder: String) -> SetupLease {
    let lease = SetupLease(id: UUID(), holder: holder)
    leases[lease.id] = holder
    if run == nil { startRun() }
    return lease
  }

  /// Gives the claim up; when no lease is left the run stops (completed work is kept by the work itself).
  public func release(_ lease: SetupLease) {
    guard leases.removeValue(forKey: lease.id) != nil else { return }
    waiters.removeValue(forKey: lease.id)?.resume(returning: .stopped)
    if leases.isEmpty, let run {
      cancelledRun = run.id
      run.task.cancel()
    }
  }

  /// Whether a holder other than `holder` keeps setup running (the app leaving the front leaves those running).
  public func isHeld(byOtherThan holder: String) -> Bool {
    leases.values.contains { $0 != holder }
  }

  public var isRunning: Bool { run != nil }

  /// Starts a run again if anyone holds a lease and none is going (a retry after a block, or new photos to read).
  public func restart() {
    if run == nil, !leases.isEmpty { startRun() }
  }

  /// How the current run ends (once its state is settled), or the last outcome when none is going.
  public func outcome() async -> SetupOutcome {
    guard run != nil else { return lastOutcome ?? .stopped }
    return await withCheckedContinuation { waiters[UUID()] = $0 }
  }

  /// Holds a lease until the run ends: acquire, wait, release. Cancelling the caller releases the lease and returns
  /// `.stopped` at once (the run goes on if another holder keeps it).
  public func runHolding(_ holder: String) async -> SetupOutcome {
    let lease = acquire(holder)
    let result = await withTaskCancellationHandler {
      await wait(lease)
    } onCancel: {
      Task { await self.release(lease) }
    }
    release(lease)
    return result
  }

  private func wait(_ lease: SetupLease) async -> SetupOutcome {
    await withCheckedContinuation { continuation in
      if leases[lease.id] == nil || Task.isCancelled {
        continuation.resume(returning: .stopped)
      } else if run == nil {
        continuation.resume(returning: lastOutcome ?? .stopped)
      } else {
        waiters[lease.id] = continuation
      }
    }
  }

  // MARK: Progress

  /// The current progress, then every change.
  public func progressUpdates() -> AsyncStream<SetupProgress> {
    let (stream, continuation) = AsyncStream.makeStream(of: SetupProgress.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    subscribers[id] = continuation
    continuation.yield(progress)
    continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
    return stream
  }

  private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

  /// Recomputes progress from the latest report; the overall fraction never goes back within a run.
  private func publish(runId: Int) {
    let (stage, stepStart, latestRun, reported) = latest.withLock { ($0.stage, $0.stepStart, $0.runId, $0.reported) }
    guard latestRun == runId, reported, run?.id == runId else { return }
    let fraction = SetupProgress.fraction(of: stage, elapsed: clock.now() - stepStart)
    let floor = progressRun == runId ? progress.overall : 0
    let next = SetupProgress(stage: stage, overall: max(floor, fraction))
    progressRun = runId
    guard next != progress else { return }
    progress = next
    for continuation in subscribers.values { continuation.yield(next) }
  }

  /// Records a report from the work (any thread): a new step (or a model step whose counter moved) restarts the creep.
  private nonisolated func report(_ stage: SetupStage, runId: Int) {
    let now = clock.now()
    latest.withLock { state in
      guard state.runId == runId else { return }
      if !state.reported || !Self.sameStep(state.stage, stage) { state.stepStart = now }
      state.stage = stage
      state.reported = true
    }
    Task { await self.publish(runId: runId) }
  }

  private static func sameStep(_ a: SetupStage, _ b: SetupStage) -> Bool {
    switch (a, b) {
    case (.model(.installing), .model(.installing)): true
    case (.model(.preparing(let d1, let t1)), .model(.preparing(let d2, let t2))): d1 == d2 && t1 == t2
    case (.model(.downloading), .model(.downloading)), (.library, .library): true
    default: false
    }
  }

  // MARK: Runs

  private func startRun() {
    runCount += 1
    let id = runCount
    let now = clock.now()
    latest.withLock { $0 = (progress.stage, now, id, false) }
    let work = work, clock = clock, tick = tick
    let task = Task<SetupOutcome, Never> { [weak self] in
      guard let self else { return .stopped }
      // Keeps a long step's creep moving between the work's own reports.
      let ticker = Task {
        while !Task.isCancelled {
          try? await clock.sleep(tick)
          await self.publish(runId: id)
        }
      }
      defer { ticker.cancel() }
      return await Self.sequence(work: work) { stage in self.report(stage, runId: id) }
    }
    run = Run(id: id, task: task)
    Task { await self.finish(id, task: task) }
  }

  /// The model, then the library; the outcome from where it stopped.
  private static func sequence(work: any SetupWork, report: @escaping @Sendable (SetupStage) -> Void) async
    -> SetupOutcome {
    do {
      try await work.readyModel { report(.model($0)) }
      try Task.checkCancellation()
      var counts = try await work.libraryCounts()
      try Task.checkCancellation()
      if !counts.isComplete {
        report(.library(counts))
        try await work.readLibrary { report(.library($0)) }
        try Task.checkCancellation()
        counts = try await work.libraryCounts()
        try Task.checkCancellation()
      }
      report(.done(counts))
      return .finished(counts)
    } catch is CancellationError {
      return .stopped
    } catch let error as SetupBlockError {
      return Task.isCancelled ? .stopped : .blocked(error.block)
    } catch {
      return Task.isCancelled ? .stopped : .blocked(.failed(String(describing: error)))
    }
  }

  private func finish(_ id: Int, task: Task<SetupOutcome, Never>) async {
    let outcome = await task.value
    publish(runId: id)
    guard run?.id == id else { return }
    run = nil
    lastOutcome = outcome
    // A holder that came while a stopped run was winding down wants setup going: start again, and everyone still
    // waiting waits for that run (released holders were answered when they left).
    let wasCancelled = cancelledRun == id
    if wasCancelled { cancelledRun = nil }
    if outcome == .stopped, wasCancelled, !leases.isEmpty {
      startRun()
      return
    }
    let waiting = waiters
    waiters = [:]
    for continuation in waiting.values { continuation.resume(returning: outcome) }
  }
}
