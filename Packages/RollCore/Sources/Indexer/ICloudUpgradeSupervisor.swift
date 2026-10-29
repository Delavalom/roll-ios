import Foundation

/// What the opt-in "Improve with iCloud originals" pass needs: Wi-Fi that is neither expensive nor constrained (Low
/// Data Mode), and external power.
public struct ICloudUpgradeConditions: Sendable, Equatable {
  public var onWiFi: Bool
  public var isExpensive: Bool
  public var isConstrained: Bool
  public var charging: Bool

  public init(onWiFi: Bool, isExpensive: Bool, isConstrained: Bool, charging: Bool) {
    self.onWiFi = onWiFi; self.isExpensive = isExpensive; self.isConstrained = isConstrained; self.charging = charging
  }

  public static let none = ICloudUpgradeConditions(onWiFi: false, isExpensive: false, isConstrained: false, charging: false)

  public var allowsUpgrade: Bool { onWiFi && !isExpensive && !isConstrained && charging }
}

/// Runs the iCloud upgrade pass only while it's allowed. Feed it every change of the network path and the battery state
/// (and of the setting and the remaining work): it starts `run` when everything holds, and the moment something fails it
/// calls `cancel` (stop the Indexer) and cancels the run's task. It starts again on a later update once all hold.
///
/// Updates are ordered: `post` (for callbacks on any thread) queues them on one stream, applied one at a time in the
/// order they were posted, so a stale "allowed" can't land after "not allowed". A stop finishes (the run has ended)
/// before another run can start; an update that arrives meanwhile is applied once it has.
public actor ICloudUpgradeSupervisor {
  private struct Update: Sendable {
    var conditions: ICloudUpgradeConditions
    var enabled: Bool
    var pending: Bool
  }

  private let run: @Sendable () async -> Void
  private let cancel: @Sendable () async -> Void
  private let intake: AsyncStream<Update>.Continuation
  private var task: Task<Void, Never>?
  private var generation = 0
  /// What the latest update asks for.
  private var allowed = false
  private var stopping = false
  /// Posted updates applied so far (tests).
  private(set) var applied = 0

  public init(run: @escaping @Sendable () async -> Void, cancel: @escaping @Sendable () async -> Void) {
    self.run = run
    self.cancel = cancel
    let (updates, intake) = AsyncStream.makeStream(of: Update.self)
    self.intake = intake
    Task { [weak self] in
      for await update in updates {
        await self?.apply(update)
      }
    }
  }

  deinit { intake.finish() }

  public var isRunning: Bool { task != nil }

  /// Queues an update; applied after every update posted before it.
  public nonisolated func post(_ conditions: ICloudUpgradeConditions, enabled: Bool, pending: Bool) {
    intake.yield(Update(conditions: conditions, enabled: enabled, pending: pending))
  }

  public func update(_ conditions: ICloudUpgradeConditions, enabled: Bool, pending: Bool) async {
    allowed = enabled && pending && conditions.allowsUpgrade
    await settle()
  }

  private func apply(_ update: Update) async {
    await self.update(update.conditions, enabled: update.enabled, pending: update.pending)
    applied += 1
  }

  /// Brings the run in line with `allowed`. While a stop is in progress it does nothing: the stop settles again when
  /// the old run has ended.
  private func settle() async {
    guard !stopping else { return }
    if allowed, task == nil {
      generation += 1
      let current = generation, run = run
      task = Task {
        await run()
        self.finished(current)
      }
    } else if !allowed, let running = task {
      stopping = true
      await cancel()
      running.cancel()
      await running.value
      task = nil
      stopping = false
      await settle()  // an update during the stop may allow a run again
    }
  }

  private func finished(_ current: Int) {
    if current == generation, !stopping { task = nil }
  }
}
