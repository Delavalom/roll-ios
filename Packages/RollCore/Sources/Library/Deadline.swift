import Foundation

/// A bounded wait for work that may never finish: a PhotoKit request whose callback never comes would otherwise hold
/// its caller (and everything queued behind it) for the whole launch.
public enum Deadline {
  /// The operation's answer, or nil when none came within `timeout` (or the caller was cancelled). On a timeout the
  /// operation's task is cancelled and left behind: its caller never waits for it to end, and a late answer is ignored.
  /// Wrap cancellation-aware requests (`OneShot`) so the cancel reaches PhotoKit too.
  public static func answer<T: Sendable>(within timeout: Duration,
                                         _ operation: @escaping @Sendable () async -> T) async -> T? {
    let shot = OneShot<T?>(cancelledValue: nil)
    let work = Task { shot.resolve(await operation()) }
    let timer = Task {
      try? await Task.sleep(for: timeout)
      if !Task.isCancelled { shot.cancel() }
    }
    let result = await shot.run { $0.setCancelAction { work.cancel() } }
    timer.cancel()
    return result
  }
}
