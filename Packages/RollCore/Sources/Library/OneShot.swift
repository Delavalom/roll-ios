import Foundation

/// Bridges a callback API to async/await with exactly-once resumption and cancellation.
///
/// PhotoKit request handlers can fire after cancellation, more than once, or before the continuation
/// exists, so the continuation lives behind a lock and only the first `resolve` wins. `cancel()`
/// (called from `withTaskCancellationHandler`) runs the registered cancel action (for example
/// `PHImageManager.cancelImageRequest`) and resolves with `cancelledValue` itself, because a cancelled
/// request may never call its handler.
public final class OneShot<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let cancelledValue: T
  private var continuation: CheckedContinuation<T, Never>?
  private var result: T?
  private var cancelRequested = false
  private var cancelAction: (@Sendable () -> Void)?

  public init(cancelledValue: T) { self.cancelledValue = cancelledValue }

  public var isResolved: Bool { lock.withLock { result != nil } }

  /// Runs `start` (which issues the request and eventually calls `resolve`) and waits for the result.
  /// `start` is skipped if the task was already cancelled.
  public func run(start: (OneShot<T>) -> Void) async -> T {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        attach(continuation)
        if !isResolved && !Task.isCancelled { start(self) }
        // Cancellation can land between the check above and the request id being stored.
        if Task.isCancelled { cancel() }
      }
    } onCancel: {
      cancel()
    }
  }

  /// First call wins; later calls (late handler callbacks) are ignored.
  public func resolve(_ value: T) {
    let waiting: CheckedContinuation<T, Never>? = lock.withLock {
      guard result == nil else { return nil }
      result = value
      defer { continuation = nil }
      return continuation
    }
    waiting?.resume(returning: value)
  }

  /// Registers what to do on cancellation (e.g. cancel the PhotoKit request id). Runs immediately if
  /// cancellation already happened.
  public func setCancelAction(_ action: @escaping @Sendable () -> Void) {
    let runNow: Bool = lock.withLock {
      if cancelRequested { return true }
      cancelAction = action
      return false
    }
    if runNow { action() }
  }

  public func cancel() {
    let action: (@Sendable () -> Void)? = lock.withLock {
      cancelRequested = true
      defer { cancelAction = nil }
      return cancelAction
    }
    action?()
    resolve(cancelledValue)
  }

  private func attach(_ waiting: CheckedContinuation<T, Never>) {
    let ready: T? = lock.withLock {
      if let result { return result }
      continuation = waiting
      return nil
    }
    if let ready { waiting.resume(returning: ready) }
  }
}
