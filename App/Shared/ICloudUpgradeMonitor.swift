import Foundation
import Indexer
import Network
import UIKit

/// Watches the network path and the battery state for as long as "Improve with iCloud originals" is on, and feeds every
/// change to `ICloudUpgradeSupervisor`: the upgrade pass runs only while the iPhone is on Wi-Fi (not expensive, not
/// Low Data Mode) and charging, and is cancelled the moment either stops holding. Both callbacks arrive on the main
/// queue and every change is posted in order (`ICloudUpgradeSupervisor.post`), so a stale state can't land last.
@MainActor
final class ICloudUpgradeMonitor {
  private let supervisor: ICloudUpgradeSupervisor
  private var conditions = ICloudUpgradeConditions.none
  private var pathMonitor: NWPathMonitor?
  private var batteryObserver: NSObjectProtocol?
  private var enabled = false
  private var pending = false

  init(supervisor: ICloudUpgradeSupervisor) { self.supervisor = supervisor }

  /// The setting and whether preview rows are left. Monitoring runs only while the setting is on.
  func refresh(enabled: Bool, pending: Bool) {
    self.enabled = enabled
    self.pending = pending
    enabled ? startMonitoring() : stopMonitoring()
    push()
  }

  private func startMonitoring() {
    guard pathMonitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let onWiFi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
      let expensive = path.isExpensive, constrained = path.isConstrained
      MainActor.assumeIsolated {
        guard let self else { return }
        self.conditions.onWiFi = onWiFi
        self.conditions.isExpensive = expensive
        self.conditions.isConstrained = constrained
        self.push()
      }
    }
    monitor.start(queue: .main)  // in order, like the battery notifications
    pathMonitor = monitor
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    conditions.charging = Self.isCharging(device.batteryState)
    batteryObserver = NotificationCenter.default.addObserver(
      forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.conditions.charging = Self.isCharging(UIDevice.current.batteryState)
        self.push()
      }
    }
  }

  private func stopMonitoring() {
    pathMonitor?.cancel()
    pathMonitor = nil
    if let batteryObserver { NotificationCenter.default.removeObserver(batteryObserver) }
    batteryObserver = nil
    conditions = .none
  }

  private func push() {
    supervisor.post(conditions, enabled: enabled, pending: pending)
  }

  private static func isCharging(_ state: UIDevice.BatteryState) -> Bool { state == .charging || state == .full }
}
