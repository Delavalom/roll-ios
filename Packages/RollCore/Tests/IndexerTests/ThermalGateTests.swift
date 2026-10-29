import Foundation
import Synchronization
import Testing
@testable import Indexer

/// Reports `.serious` for the first `hotReads` reads, then `.nominal`.
final class FakeThermal: ThermalStateProvider {
  private let state: Mutex<(reads: Int, hotReads: Int, hot: ProcessInfo.ThermalState)>

  init(hotReads: Int = 0, hot: ProcessInfo.ThermalState = .serious) {
    state = Mutex((0, hotReads, hot))
  }

  var reads: Int { state.withLock { $0.reads } }

  var thermalState: ProcessInfo.ThermalState {
    state.withLock { s in
      s.reads += 1
      return s.reads <= s.hotReads ? s.hot : .nominal
    }
  }
}

struct ThermalGateTests {
  @Test func passesStraightThroughWhenCool() async throws {
    let thermal = FakeThermal()
    let gate = ThermalGate(provider: thermal, pollInterval: .milliseconds(1))
    #expect(try await gate.waitUntilOK() == 0)
    #expect(thermal.reads == 1)
  }

  @Test func aGateThatPausesAtFairWaitsWhileFair() async throws {
    #expect(ThermalGate().pausesAt == .serious, "the Indexer's gate is unchanged")
    let thermal = FakeThermal(hotReads: 2, hot: .fair)
    #expect(try await ThermalGate(provider: thermal, pollInterval: .milliseconds(1), pausesAt: .fair).waitUntilOK() == 2)
    #expect(try await ThermalGate(provider: FakeThermal(hotReads: 2, hot: .fair), pollInterval: .milliseconds(1))
      .waitUntilOK() == 0)
  }

  @Test func waitsWhileSeriousOrCriticalThenResumes() async throws {
    for hot in [ProcessInfo.ThermalState.serious, .critical] {
      let thermal = FakeThermal(hotReads: 2, hot: hot)
      let gate = ThermalGate(provider: thermal, pollInterval: .milliseconds(1))
      #expect(try await gate.waitUntilOK() == 2)
      #expect(thermal.reads == 3)
    }
  }

  @Test func fairDoesNotPause() async throws {
    let thermal = FakeThermal(hotReads: 5, hot: .fair)
    let gate = ThermalGate(provider: thermal, pollInterval: .milliseconds(1))
    #expect(gate.isThrottled == false)
    #expect(try await gate.waitUntilOK() == 0)
  }

  @Test func cancellationEndsTheWait() async throws {
    let gate = ThermalGate(provider: FakeThermal(hotReads: .max), pollInterval: .seconds(60))
    let task = Task { try await gate.waitUntilOK() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func defaultsToTheSystemProviderAndFiveSeconds() {
    let gate = ThermalGate()
    #expect(gate.pollInterval == .seconds(5))
    #expect(gate.provider is SystemThermalState)
  }
}
