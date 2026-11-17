import Foundation
import Observation
import Setup
import UIKit
import UserNotifications
import os

/// The on-device AI setup as the screens see it: the coordinator's progress, whether the person ever started it, the
/// "tell me when it's ready" choice, and the foreground runner's lease (held while Roll is on screen).
///
/// The sequence itself lives in `SetupCoordinator` (RollCore `Setup`); the work it sequences is the app's own model
/// loader and indexing loop (`AppSetupWork`, AppModel+Setup.swift).
@Observable @MainActor
final class SetupModel {
  static let startedKey = "setupStarted"
  static let finishedOnceKey = "setupFinishedOnce"
  static let notifyKey = "setupNotifyWhenReady"
  static let notifiedKey = "setupNotified"

  /// The runners' names (`SetupCoordinator.acquire`).
  enum Holder {
    static let foreground = "foreground"
    static let continued = "continued"
    static let overnight = "overnight"
  }

  let coordinator: SetupCoordinator
  private(set) var progress: SetupProgress = .initial
  /// The person tapped "Set up" at least once (onboarding's setup step or Home).
  private(set) var started: Bool
  /// A run reached `.done` at least once on this install: a later "not done" is an update, a purge or new photos.
  private(set) var finishedOnce: Bool
  /// Post one notification when setup finishes while Roll isn't on screen.
  private(set) var notifyWhenReady: Bool
  /// iOS 26's continued task holds the run, so setup goes on when Roll leaves the screen.
  var continuing = false

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var frontLease: Task<SetupLease, Never>?
  @ObservationIgnored private var progressTask: Task<Void, Never>?

  init(work: any SetupWork, defaults: UserDefaults) {
    coordinator = SetupCoordinator(work: work)
    self.defaults = defaults
    started = defaults.bool(forKey: Self.startedKey)
    finishedOnce = defaults.bool(forKey: Self.finishedOnceKey)
    notifyWhenReady = defaults.bool(forKey: Self.notifyKey)
  }

  /// iOS 26 and later keep setup going in the background after the tap; earlier versions while Roll is open, and
  /// overnight while charging.
  var continuesInBackground: Bool {
    if #available(iOS 26.0, *) { true } else { false }
  }

  var isDone: Bool {
    if case .done = progress.stage { true } else { false }
  }

  /// The current stage's own share of the bar (0...1): the model's steps, or the photos read. Home's card shows this,
  /// so "120 MB of 359 MB" sits over a third-full bar, not the whole setup's 5%.
  var stageFraction: Double {
    let p = progress.overall, modelEnd = SetupProgress.modelEnd
    switch progress.stage {
    case .unknown: return 0
    case .model: return min(1, p / modelEnd)
    case .library: return min(1, max(0, (p - modelEnd) / (1 - modelEnd)))
    case .done: return 1
    }
  }

  /// Photos read and in all, once the run reaches the library.
  var counts: LibraryCounts? {
    switch progress.stage {
    case .library(let counts), .done(let counts): counts
    default: nil
    }
  }

  /// Follows the coordinator's progress for the screens. Called once at launch.
  func observe() {
    guard progressTask == nil else { return }
    let coordinator = coordinator
    progressTask = Task { [weak self] in
      for await progress in await coordinator.progressUpdates() {
        guard let self else { return }
        self.progress = progress
        if case .done = progress.stage {
          if !self.finishedOnce {
            self.finishedOnce = true
            self.defaults.set(true, forKey: Self.finishedOnceKey)
          }
          // Seen finishing on screen: nothing to tell later (a background run's instant `.finished` that night
          // mustn't notify).
          if UIApplication.shared.applicationState == .active { self.defaults.set(true, forKey: Self.notifiedKey) }
        }
      }
    }
  }

  func markStarted() {
    guard !started else { return }
    started = true
    defaults.set(true, forKey: Self.startedKey)
  }

  // MARK: Foreground runner

  /// Holds the foreground lease (no-op while held): setup advances whenever Roll is on screen.
  func holdInFront() {
    guard frontLease == nil else { return }
    let coordinator = coordinator
    frontLease = Task { await coordinator.acquire(Holder.foreground) }
  }

  /// Gives the foreground lease up (Roll left the screen). Returns whether another runner still holds setup, in which
  /// case the indexing it relies on must keep going.
  func releaseFront() async -> Bool {
    let coordinator = coordinator
    if let lease = frontLease {
      frontLease = nil
      await coordinator.release(await lease.value)
    }
    return await coordinator.isHeld(byOtherThan: Holder.foreground)
  }

  /// A new run for the holders still there, if none is going (after a retry, or back on screen after a block).
  func restart() {
    let coordinator = coordinator
    Task { await coordinator.restart() }
  }

  // MARK: Notification

  /// "Tell me when it's ready": asks for permission the first time; on a no, the choice stays off.
  func setNotifyWhenReady(_ on: Bool) async {
    guard on else {
      notifyWhenReady = false
      defaults.set(false, forKey: Self.notifyKey)
      return
    }
    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    notifyWhenReady = granted
    defaults.set(granted, forKey: Self.notifyKey)
  }

  /// A background runner's run ended: when it finished and the person asked, one notification (only once per install,
  /// and never while Roll is on screen, where the screen itself says so).
  func runEnded(_ outcome: SetupOutcome) {
    guard case .finished(let counts) = outcome, notifyWhenReady, !defaults.bool(forKey: Self.notifiedKey),
          UIApplication.shared.applicationState != .active else { return }
    defaults.set(true, forKey: Self.notifiedKey)
    let content = UNMutableNotificationContent()
    content.title = "Roll is ready"
    content.body = counts.total > 0
      ? "Roll has read your \(counts.total.formatted()) photos. Describe one to find it."
      : "The on-device AI is ready. Describe a photo to find it."
    content.sound = .default
    let request = UNNotificationRequest(identifier: "setup.finished", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        Logger(subsystem: "com.delavalom.roll", category: "setup")
          .error("the setup notification failed: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
