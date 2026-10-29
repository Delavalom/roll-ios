import Foundation
import Squish
import Synchronization
import UIKit

/// `BackgroundExecution` over `UIApplication.beginBackgroundTask`, so a squish item can finish briefly after the app
/// leaves the foreground. Per the contract: the task is ended inside its expiration handler (after `onExpiration`),
/// and `end` is idempotent.
final class UIKitBackgroundExecution: BackgroundExecution {
  private struct State {
    var next = 1
    var tasks: [Int: UIBackgroundTaskIdentifier] = [:]
  }

  private let state = Mutex(State())

  func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int? {
    let token = state.withLock { s in
      defer { s.next += 1 }
      return s.next
    }
    let identifier = Self.onMain {
      UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
        onExpiration()
        self?.end(token)
      }
    }
    guard identifier != .invalid else { return nil }
    state.withLock { $0.tasks[token] = identifier }
    return token
  }

  func end(_ token: Int) {
    guard let identifier = state.withLock({ $0.tasks.removeValue(forKey: token) }) else { return }
    Self.onMain { UIApplication.shared.endBackgroundTask(identifier) }
  }

  private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
  }
}
