import BackgroundTasks
import Foundation
import Setup
import os

/// iOS 26's continued processing task for setup: started by the person's tap, it keeps the run going when Roll leaves
/// the screen, with iOS's own progress UI (title, subtitle, bar). Strategy `.queue`: if iOS can't start it right away
/// it starts as soon as it can. iOS may still stop it (the person cancels it, or the system needs the resources);
/// the overnight job and the next launch finish the rest.
///
/// The identifier is registered on first use (dynamic registration: `com.delavalom.roll.setup.*` in Info.plist), once
/// per process, as BackgroundTasks allows.
@available(iOS 26.0, *)
@MainActor
enum ContinuedSetup {
  static let identifier = "com.delavalom.roll.setup.run"
  private static var registered = false
  private static let log = Logger(subsystem: "com.delavalom.roll", category: "setup")

  static func submit(app: AppModel) {
    if !registered {
      registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak app] task in
        MainActor.assumeIsolated {
          guard let task = task as? BGContinuedProcessingTask, let app else {
            task.setTaskCompleted(success: false)
            return
          }
          run(task, app: app)
        }
      }
      guard registered else {
        log.error("the continued setup task could not be registered")
        return
      }
    }
    guard !app.setup.continuing else { return }
    // Waiting for Wi-Fi shows no progress, and iOS may stop a task that looks stalled; the download waits in its
    // background session anyway. The card's "Finish setting up" submits it once the download can go.
    if case .waiting = app.modelState { return }
    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Setting up Roll",
                                                   subtitle: "Getting the on-device AI ready")
    request.strategy = .queue
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Already queued or running, or iOS declined: setup still runs while Roll is open and overnight.
      log.error("the continued setup task wasn't submitted: \(String(describing: error), privacy: .public)")
    }
  }

  private static func run(_ task: BGContinuedProcessingTask, app: AppModel) {
    let box = TaskBox(task: task)
    task.progress.totalUnitCount = 1000
    app.setup.continuing = true
    let coordinator = app.setup.coordinator
    let runner = Task { @MainActor in
      let mirror = Task { @MainActor in
        var last: (title: String, subtitle: String)?
        for await progress in await coordinator.progressUpdates() {
          box.task.progress.completedUnitCount = Int64((progress.overall * 1000).rounded())
          let text = SetupText.backgroundTitle(for: progress.stage)
          if last?.title != text.title || last?.subtitle != text.subtitle {
            box.task.updateTitle(text.title, subtitle: text.subtitle)
            last = text
          }
        }
      }
      let outcome = await coordinator.runHolding(SetupModel.Holder.continued)
      mirror.cancel()
      app.setup.continuing = false
      if case .finished = outcome { box.task.progress.completedUnitCount = 1000 }
      // First the hand-off (flush and stop indexing, ask for the overnight job, notify), while the task still keeps
      // Roll running; completing it first could let iOS suspend Roll mid-flush.
      await app.setupRunEnded(outcome)
      box.task.setTaskCompleted(success: { if case .finished = outcome { true } else { false } }())
    }
    task.expirationHandler = { runner.cancel() }
  }

  /// `BGTask` isn't Sendable; its progress, title and completion APIs are thread-safe.
  private struct TaskBox: @unchecked Sendable {
    let task: BGContinuedProcessingTask
  }
}
