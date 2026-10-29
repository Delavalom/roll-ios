import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

public enum BatteryState: Sendable, Equatable {
  case unknown, unplugged, charging, full
}

/// One reading. A `nil` value means "unavailable" (the kernel call failed, or there was no earlier
/// sample to diff against); the UI shows that as unavailable rather than as zero.
public struct DeviceSample: Sendable, Equatable {
  public var date: Date
  public var ramUsedFraction: Double?
  public var cpuTotal: Double?

  public init(date: Date, ramUsedFraction: Double?, cpuTotal: Double?) {
    self.date = date; self.ramUsedFraction = ramUsedFraction; self.cpuTotal = cpuTotal
  }
}

/// Samples device readings about once a second while the Monitor screen is visible. Read-only (ADR-0002).
///
/// Lifecycle: `start()` on appear, `stop()` on disappear. `stop()` cancels the loop, clears the history
/// (a later `start()` begins a fresh 60-s chart) and turns battery monitoring off if this sampler turned it on.
/// An `isolated deinit` does the same cleanup if the sampler is released while running (the compiler
/// back-deploys it to the package's iOS 18.0 / macOS 15.0 floor). The loop holds the sampler weakly.
/// Storage is not sampled here; read it with `StorageStats.snapshot()`.
@MainActor
@Observable
public final class DeviceSampler {
  public static let capacity = 60

  /// Oldest first, at most `capacity` entries.
  public private(set) var samples: [DeviceSample] = []
  public private(set) var perCoreLoad: [Double] = []
  public private(set) var memory: MemorySnapshot?
  public private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
  /// 0...1, or nil when unknown (simulator, macOS, monitoring unavailable).
  public private(set) var batteryLevel: Float?
  public private(set) var batteryState: BatteryState = .unknown
  public private(set) var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime

  @ObservationIgnored private let interval: Duration
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var prevTicks: [CoreTicks] = []
  @ObservationIgnored private var enabledBatteryMonitoring = false

  /// - Parameter interval: time between samples; tests shorten it.
  public init(interval: Duration = .seconds(1)) { self.interval = interval }

  isolated deinit {
    loop?.cancel()
    #if canImport(UIKit)
    if enabledBatteryMonitoring { UIDevice.current.isBatteryMonitoringEnabled = false }
    #endif
  }

  public var isRunning: Bool { loop != nil }

  /// Takes a first reading immediately, then one per `interval` on a fixed schedule.
  public func start() {
    guard loop == nil else { return }
    #if canImport(UIKit)
    if !UIDevice.current.isBatteryMonitoringEnabled {
      UIDevice.current.isBatteryMonitoringEnabled = true
      enabledBatteryMonitoring = true
    }
    #endif
    sample()
    loop = Task { [weak self, interval] in
      let clock = ContinuousClock()
      var deadline = clock.now + interval
      while !Task.isCancelled {
        try? await clock.sleep(until: deadline)
        guard !Task.isCancelled, let self else { return }
        self.sample()
        deadline = DeviceSampler.nextDeadline(after: deadline, now: clock.now, interval: interval)
      }
    }
  }

  public func stop() {
    loop?.cancel()
    loop = nil
    samples = []
    perCoreLoad = []
    prevTicks = []
    #if canImport(UIKit)
    if enabledBatteryMonitoring {
      UIDevice.current.isBatteryMonitoringEnabled = false
      enabledBatteryMonitoring = false
    }
    #endif
  }

  /// The next tick on the fixed grid `deadline + k * interval` that lies after `now`, so a slow sample
  /// delays nothing and a long stall skips missed ticks instead of firing a burst.
  nonisolated static func nextDeadline(after deadline: ContinuousClock.Instant, now: ContinuousClock.Instant,
                                       interval: Duration) -> ContinuousClock.Instant {
    var next = deadline + interval
    while next <= now { next += interval }
    return next
  }

  /// Takes one reading now. `start()` and the loop call this; tests call it directly. The first reading after
  /// `start()` has no CPU value because load needs two tick snapshots.
  func sample(now: Date = Date()) {
    let ticks = HostStats.cpuTicks()
    var cpuTotal: Double?
    if !prevTicks.isEmpty, !ticks.isEmpty {
      let load = HostStats.load(prev: prevTicks, now: ticks)
      perCoreLoad = load.perCore
      cpuTotal = load.total
    } else {
      perCoreLoad = []
    }
    prevTicks = ticks
    memory = HostStats.memory()
    append(DeviceSample(date: now, ramUsedFraction: memory?.usedFraction, cpuTotal: cpuTotal))
    thermalState = ProcessInfo.processInfo.thermalState
    uptime = ProcessInfo.processInfo.systemUptime
    readBattery()
  }

  func append(_ sample: DeviceSample) {
    samples.append(sample)
    if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
  }

  private func readBattery() {
    #if canImport(UIKit)
    let device = UIDevice.current
    batteryLevel = device.batteryLevel < 0 ? nil : device.batteryLevel
    switch device.batteryState {
    case .unplugged: batteryState = .unplugged
    case .charging: batteryState = .charging
    case .full: batteryState = .full
    default: batteryState = .unknown
    }
    #endif
  }
}
