import Foundation
import Monitor
import Observation
import Overview
import SwiftUI

/// Read-only device readings (spec §9, ADR-0002): the sampler runs only while the screen is visible.
@Observable @MainActor
final class MonitorModel {
  static let footer = "Live readings from your iPhone. Roll doesn't change how your phone runs."

  private(set) var storage: StorageSnapshot?

  @ObservationIgnored private let app: AppModel

  init(app: AppModel) { self.app = app }

  var sampler: DeviceSampler { app.sampler }
  var library: CleanupSummary { app.home.summary }

  /// Roll's estimate of the photos and videos stored on this iPhone, never more than the space in use.
  var photosOnDevice: Int64 {
    CleanupSummary.capped(library.library.onDeviceBytes, deviceTotal: storage?.total, deviceAvailable: storage?.available)
  }

  /// Called from `.onAppear`.
  func start() {
    storage = try? StorageStats.snapshot()
    sampler.start()
  }

  /// Called from `.onDisappear`.
  func stop() { sampler.stop() }

  var ramText: String {
    guard let memory = sampler.memory else { return "Unavailable" }
    return "\(ByteFormat.short(Int64(memory.used))) of \(ByteFormat.short(Int64(memory.total)))"
  }

  var cpuTotal: Double? { sampler.samples.last?.cpuTotal }

  var thermalText: String {
    switch sampler.thermalState {
    case .nominal: "Normal"
    case .fair: "Fair"
    case .serious: "Serious"
    case .critical: "Critical"
    @unknown default: "Unknown"
    }
  }

  var batteryText: String {
    guard let level = sampler.batteryLevel else { return "Unavailable" }
    let state = switch sampler.batteryState {
    case .charging: " · charging"
    case .full: " · full"
    case .unplugged, .unknown: ""
    }
    return "\(Int((level * 100).rounded()))%\(state)"
  }

  var uptimeText: String {
    Duration.seconds(sampler.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
  }

  var storageText: String {
    guard let storage else { return "Unavailable" }
    return "\(ByteFormat.short(storage.available)) available of \(ByteFormat.short(storage.total))"
  }
}
