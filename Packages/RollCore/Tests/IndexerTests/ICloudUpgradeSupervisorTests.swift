import Foundation
import Synchronization
import Testing
@testable import Indexer

/// The opt-in iCloud upgrade runs only while Wi-Fi (not expensive, not constrained) and charging both hold: it starts
/// when they do, is cancelled the moment either fails, and resumes when both hold again.
struct ICloudUpgradeSupervisorTests {
  static let good = ICloudUpgradeConditions(onWiFi: true, isExpensive: false, isConstrained: false, charging: true)

  @Test func everyConditionMustHold() {
    #expect(Self.good.allowsUpgrade)
    var c = Self.good; c.onWiFi = false; #expect(!c.allowsUpgrade)
    c = Self.good; c.isExpensive = true; #expect(!c.allowsUpgrade)
    c = Self.good; c.isConstrained = true; #expect(!c.allowsUpgrade)
    c = Self.good; c.charging = false; #expect(!c.allowsUpgrade)
  }

  final class Log: Sendable {
    private let events = Mutex<[String]>([])
    func add(_ e: String) { events.withLock { $0.append(e) } }
    var all: [String] { events.withLock { $0 } }
  }

  /// A run that lasts until it's cancelled (or `finish` is set), like a long upgrade pass.
  static func supervisor(_ log: Log, finishes: Bool = false) -> ICloudUpgradeSupervisor {
    ICloudUpgradeSupervisor(
      run: {
        log.add("run")
        if finishes { return }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        log.add("run ended")
      },
      cancel: { log.add("cancel") })
  }

  @Test func startsWhenAllowedAndStopsTheMomentAConditionFails() async throws {
    let log = Log()
    let s = Self.supervisor(log)
    await s.update(Self.good, enabled: true, pending: true)
    await s.update(Self.good, enabled: true, pending: true)  // no second run
    try await waitFor { log.all == ["run"] }
    var offWiFi = Self.good; offWiFi.onWiFi = false
    await s.update(offWiFi, enabled: true, pending: true)
    try await waitFor { log.all == ["run", "cancel", "run ended"] }
    #expect(await !s.isRunning)
    await s.update(Self.good, enabled: true, pending: true)  // both hold again: resume
    try await waitFor { log.all.filter { $0 == "run" }.count == 2 }
    var unplugged = Self.good; unplugged.charging = false
    await s.update(unplugged, enabled: true, pending: true)
    try await waitFor { log.all.filter { $0 == "cancel" }.count == 2 }
  }

  @Test func turningTheSettingOffOrRunningOutOfWorkStopsIt() async throws {
    let log = Log()
    let s = Self.supervisor(log)
    await s.update(Self.good, enabled: false, pending: true)
    await s.update(Self.good, enabled: true, pending: false)
    #expect(log.all.isEmpty)
    await s.update(Self.good, enabled: true, pending: true)
    try await waitFor { log.all == ["run"] }
    await s.update(Self.good, enabled: false, pending: true)
    try await waitFor { log.all.contains("cancel") }
  }

  @Test func aRunThatFinishesCanStartAgainOnTheNextUpdate() async throws {
    let log = Log()
    let s = Self.supervisor(log, finishes: true)
    await s.update(Self.good, enabled: true, pending: true)
    try await waitFor { await !s.isRunning }
    await s.update(Self.good, enabled: true, pending: true)
    try await waitFor { log.all == ["run", "run"] }
    #expect(!log.all.contains("cancel"))
  }

  /// Counts runs alive at once; `cancel` can be slow, like stopping the Indexer mid-asset.
  final class Runs: Sendable {
    private let state = Mutex((alive: 0, maxAlive: 0, started: 0))
    var maxAlive: Int { state.withLock { $0.maxAlive } }
    var started: Int { state.withLock { $0.started } }
    var alive: Int { state.withLock { $0.alive } }
    func supervisor(_ log: Log, slowCancel: Duration = .zero) -> ICloudUpgradeSupervisor {
      ICloudUpgradeSupervisor(
        run: {
          self.state.withLock { $0.alive += 1; $0.started += 1; $0.maxAlive = max($0.maxAlive, $0.alive) }
          log.add("run")
          while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
          self.state.withLock { $0.alive -= 1 }
          log.add("run ended")
        },
        cancel: {
          log.add("cancel")
          if slowCancel > .zero { try? await Task.sleep(for: slowCancel) }
        })
    }
  }

  /// Network-path and battery callbacks post from any thread. Each update used to go in its own Task, so a stale
  /// "allowed" could land after "not allowed" and leave the pass downloading off Wi-Fi.
  @Test func postedUpdatesApplyInTheOrderTheyWerePosted() async throws {
    let log = Log(), runs = Runs()
    let s = runs.supervisor(log)
    var offWiFi = Self.good; offWiFi.onWiFi = false
    for _ in 0..<40 {
      s.post(Self.good, enabled: true, pending: true)
      s.post(offWiFi, enabled: true, pending: true)
    }
    try await waitFor { await s.applied == 80 }
    try await waitFor { runs.alive == 0 }
    #expect(await !s.isRunning, "the last update said not allowed")
    #expect(runs.maxAlive <= 1)
    #expect(log.all.last != "run")
  }

  /// `update` gave up its run before cancelling it, so another update could start a second run while the first was
  /// still downloading.
  @Test func aStopFinishesBeforeANewRunStarts() async throws {
    let log = Log(), runs = Runs()
    let s = runs.supervisor(log, slowCancel: .milliseconds(40))
    await s.update(Self.good, enabled: true, pending: true)
    try await waitFor { runs.started == 1 }
    var unplugged = Self.good; unplugged.charging = false
    let stopping = Task { await s.update(unplugged, enabled: true, pending: true) }
    try await waitFor { log.all.contains("cancel") }
    await s.update(Self.good, enabled: true, pending: true)  // plugged back in mid-stop
    await stopping.value
    try await waitFor { runs.started == 2 }
    #expect(runs.maxAlive == 1, "the old run ended before the new one started")
    #expect(log.all == ["run", "cancel", "run ended", "run"])
    #expect(await s.isRunning, "the latest update allows it")
  }

  private func waitFor(_ condition: () async -> Bool) async throws {
    for _ in 0..<2000 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out")
  }
}
