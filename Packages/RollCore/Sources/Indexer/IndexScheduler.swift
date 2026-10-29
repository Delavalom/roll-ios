import Foundation
import Synchronization

/// Background indexing through a `BGProcessingTask` that needs external power.
///
/// App wiring (Task 13):
/// 1. `RollApp.init` calls `IndexScheduler.register(indexer:)`. BackgroundTasks requires registration
///    before the app finishes launching, and the identifier is listed in Info.plist
///    (`BGTaskSchedulerPermittedIdentifiers`). The closure returns the app's Indexer, or nil if it
///    isn't built yet.
/// 2. On `scenePhase == .background`: `await IndexScheduler.appDidEnterBackground(indexer:)` (flush, stop
///    the foreground run, ask for a background run if work is left).
/// 3. With a text pass (`TextIndexer`), pass it as `text:` to both: the background run reads words after indexing.
public enum IndexScheduler {
  public static let taskIdentifier = "com.delavalom.roll.index"

  /// The body of a background run, without BackgroundTasks types so it can be tested on macOS.
  /// Runs `indexer.run()`, then the text pass if there is one (`text`, after a finished index run: words are read
  /// from analysed images only); the expiration handler stops both (`indexer.cancel()` is a hard stop, even for
  /// a run the Indexer keeps alive; completed work is flushed or committed first). Reschedules if work is left,
  /// counting embedding work even when no embedder is attached yet (the model may load next time) and unread
  /// images, but not assets whose loads keep failing. Reports completion last (success only when both finished).
  @discardableResult
  public static func perform(
    indexer: @escaping @Sendable () async -> Indexer?,
    text: @escaping @Sendable () async -> TextIndexer? = { nil },
    setExpirationHandler: (@escaping @Sendable () -> Void) -> Void,
    reschedule: @escaping @Sendable () -> Void,
    complete: @escaping @Sendable (Bool) -> Void
  ) -> Task<Void, Never> {
    let resolved = ResolvedIndexer()
    let work = Task {
      guard let indexer = await indexer() else {
        reschedule()
        complete(false)
        return
      }
      resolved.set(indexer)
      var success = false
      do {
        try await indexer.run()
        success = true
      } catch is CancellationError {
      } catch {
        IndexerLog.logger.error("background index run failed: \(String(describing: error))")
      }
      let reader = await text()
      if success, let reader {
        do { try await reader.run() } catch {
          success = false
          if !(error is CancellationError) {
            IndexerLog.logger.error("background text pass failed: \(String(describing: error))")
          }
        }
      }
      // Let the stopped run finish its flush before reporting completion.
      await indexer.waitUntilIdle()
      // Database reads fail in a cancelled task, so ask from a fresh one.
      let pending = await Task {
        let index = (try? await indexer.pendingCount(includingEmbedding: true)) ?? 1
        let words = reader == nil ? 0 : ((try? await reader?.pendingCount()) ?? 1)
        return index + words
      }.value
      if pending > 0 { reschedule() }
      complete(success)
    }
    setExpirationHandler {
      work.cancel()
      if let indexer = resolved.get() { Task { await indexer.cancel() } }
    }
    return work
  }

  /// What the app does when it goes to the background: flush what is computed, stop the foreground run
  /// (iOS would suspend it mid-asset) and the text pass (it commits what it read), wait for the final flush, then
  /// `schedule()` if work is left (index work, or images whose words are unread).
  public static func prepareForBackground(indexer: Indexer, text: TextIndexer? = nil,
                                          schedule: @Sendable () -> Void) async {
    do { try await indexer.flush() } catch {
      IndexerLog.logger.error("background flush failed: \(String(describing: error))")
    }
    await text?.cancel()
    await indexer.cancel()
    await indexer.waitUntilIdle()
    let index = (try? await indexer.pendingCount(includingEmbedding: true)) ?? 0
    let words = (try? await text?.pendingCount()) ?? 0
    if index + words > 0 { schedule() }
  }
}

/// The indexer a background task resolved, for its expiration handler.
private final class ResolvedIndexer: Sendable {
  private let indexer = Mutex<Indexer?>(nil)
  func set(_ value: Indexer) { indexer.withLock { $0 = value } }
  func get() -> Indexer? { indexer.withLock { $0 } }
}

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks

extension IndexScheduler {
  /// `BGTask` is not Sendable; its completion and expiration APIs are thread-safe.
  private struct TaskBox: @unchecked Sendable {
    let task: BGTask
  }

  /// Registers the launch handler. Call from `RollApp.init`, before launch finishes. Returns false if
  /// the identifier is missing from Info.plist.
  @discardableResult
  public static func register(indexer: @escaping @Sendable () async -> Indexer?,
                              text: @escaping @Sendable () async -> TextIndexer? = { nil }) -> Bool {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
      let box = TaskBox(task: task)
      perform(
        indexer: indexer,
        text: text,
        setExpirationHandler: { handler in box.task.expirationHandler = handler },
        reschedule: { submit() },
        complete: { box.task.setTaskCompleted(success: $0) })
    }
  }

  /// Call on `scenePhase == .background`: flushes, stops the foreground run and submits a background
  /// request if work is left (see `prepareForBackground`).
  public static func appDidEnterBackground(indexer: Indexer, text: TextIndexer? = nil) async {
    await prepareForBackground(indexer: indexer, text: text) { submit() }
  }

  /// Submits the request: external power required, no network needed. A pending request with the
  /// same identifier is replaced.
  public static func submit() {
    let request = BGProcessingTaskRequest(identifier: taskIdentifier)
    request.requiresExternalPower = true
    request.requiresNetworkConnectivity = false
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      IndexerLog.logger.error("could not schedule background indexing: \(String(describing: error))")
    }
  }
}
#endif
