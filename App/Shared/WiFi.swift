import Library
import Synchronization
import Network

/// Whether the current path is Wi-Fi (or wired). iCloud downloads for squish and swipe cards run only then (spec §8).
/// The rule is `NetworkPath.allowsICloudDownloads`: an expensive path (cellular, a personal hotspot) never downloads;
/// Low Data Mode (`isConstrained`) is deliberately not checked, so cards may download in it.
enum WiFi {
  static func isAvailable() async -> Bool {
    await withCheckedContinuation { continuation in
      let monitor = NWPathMonitor()
      let resumed = Once()
      monitor.pathUpdateHandler = { path in
        guard resumed.claim() else { return }
        monitor.cancel()
        continuation.resume(returning: NetworkPath(path).allowsICloudDownloads)
      }
      monitor.start(queue: .global(qos: .utility))
    }
  }

  /// `isAvailable`'s answer now and after each path change, until the iteration ends.
  static func changes() -> AsyncStream<Bool> {
    AsyncStream { continuation in
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { continuation.yield(NetworkPath($0).allowsICloudDownloads) }
      continuation.onTermination = { _ in monitor.cancel() }
      monitor.start(queue: .global(qos: .utility))
    }
  }
}

private extension NetworkPath {
  init(_ path: NWPath) {
    self.init(isSatisfied: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained,
              usesWiFiOrWired: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
  }
}

private final class Once: Sendable {
  private let done = Mutex(false)
  func claim() -> Bool { done.withLock { was in defer { was = true }; return !was } }
}
