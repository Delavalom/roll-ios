import Foundation

/// Where the thermal state comes from; injectable so tests can simulate a hot device.
public protocol ThermalStateProvider: Sendable {
  var thermalState: ProcessInfo.ThermalState { get }
}

public struct SystemThermalState: ThermalStateProvider {
  public init() {}
  public var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

/// Holds indexing back while the device is hot: waits while the state is `.serious` or `.critical`,
/// polling every `pollInterval` (5 s by default), and lets work resume at `.fair` or cooler (spec §4).
/// Lower-priority work (the text pass, `TextIndexer`) passes `pausesAt: .fair` to wait until the device is cool.
public struct ThermalGate: Sendable {
  public let provider: any ThermalStateProvider
  public let pollInterval: Duration
  /// The coolest state that pauses work.
  public let pausesAt: ProcessInfo.ThermalState

  public init(provider: any ThermalStateProvider = SystemThermalState(), pollInterval: Duration = .seconds(5),
              pausesAt: ProcessInfo.ThermalState = .serious) {
    self.provider = provider
    self.pollInterval = pollInterval
    self.pausesAt = pausesAt
  }

  public var isThrottled: Bool {
    provider.thermalState.rawValue >= pausesAt.rawValue
  }

  /// Returns at once when the device is cool enough; otherwise sleeps and re-checks. Returns how many
  /// polls it slept. Cancellation ends the wait with `CancellationError`.
  @discardableResult
  public func waitUntilOK() async throws(CancellationError) -> Int {
    var polls = 0
    while isThrottled {
      do { try await Task.sleep(for: pollInterval) } catch { throw CancellationError() }
      polls += 1
    }
    return polls
  }
}
