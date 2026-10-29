import ModelInstall
import Network
import Synchronization

/// The current network path for the model download's policy (`DownloadPolicy`). Separate from `WiFi.isAvailable()`,
/// which ignores Low Data Mode on purpose (small, user-initiated iCloud views may download in it); the model download
/// doesn't.
enum NetworkPathProbe {
  static func current() async -> NetworkPath {
    await withCheckedContinuation { continuation in
      let monitor = NWPathMonitor()
      let resumed = ResumeOnce()
      monitor.pathUpdateHandler = { path in
        guard resumed.claim() else { return }
        monitor.cancel()
        continuation.resume(returning: NetworkPath(
          isSatisfied: path.status == .satisfied,
          isWiFi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
          isExpensive: path.isExpensive, isConstrained: path.isConstrained))
      }
      monitor.start(queue: .global(qos: .utility))
    }
  }
}

private final class ResumeOnce: Sendable {
  private let done = Mutex(false)
  func claim() -> Bool { done.withLock { was in defer { was = true }; return !was } }
}
