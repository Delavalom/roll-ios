import Foundation
import Indexer
import Setup
import UIKit

/// The app's `SetupWork`: its model loader (`loadModel`) and its indexing loop (`startIndexing`), reached on the main
/// actor through a weak bridge (the coordinator is built before `AppModel` finishes initialising).
struct AppSetupWork: SetupWork {
  let bridge: SetupBridge

  func readyModel(report: @escaping @Sendable (ModelStep) -> Void) async throws {
    guard let app = await bridge.app else { throw CancellationError() }
    try await app.readyModelForSetup(report: report)
  }

  func libraryCounts() async throws -> LibraryCounts {
    guard let app = await bridge.app else { throw CancellationError() }
    return try await app.setupLibraryCounts()
  }

  func readLibrary(report: @escaping @Sendable (LibraryCounts) -> Void) async throws {
    guard let app = await bridge.app else { throw CancellationError() }
    try await app.readLibraryForSetup(report: report)
  }
}

@MainActor
final class SetupBridge {
  weak var app: AppModel?
}

extension AppModel {
  /// How often the bridge reads the model's state and the library counts while it waits.
  static let setupPoll: Duration = .milliseconds(250)
  /// Indexing rounds a setup run tries before saying the read didn't finish (a round can stop on an error).
  static let setupReadRounds = 3

  // MARK: - Runners

  /// The one tap ("Set up", "Finish setting up"): setup runs now, and on iOS 26 keeps running when Roll leaves the
  /// screen (`ContinuedSetup`).
  func beginSetup() {
    setup.markStarted()
    holdSetupInFront()
    setup.restart()
    if #available(iOS 26.0, *) { ContinuedSetup.submit(app: self) }
  }

  /// The foreground runner: holds setup while Roll is on screen, once the person is past onboarding (or started setup
  /// in it) and Photos can be read.
  func holdSetupInFront() {
    guard onboardingComplete || setup.started, access.canRead else { return }
    setup.holdInFront()
  }

  /// The overnight runner (`IndexScheduler.perform(setUp:)`): the whole setup before the job's own index run.
  nonisolated func runSetupOvernight() async {
    let coordinator = setup.coordinator
    let outcome = await coordinator.runHolding(SetupModel.Holder.overnight)
    await setup.runEnded(outcome)
  }

  /// A background runner's run ended. When Roll is in the background and no runner holds setup any more, indexing
  /// stops cleanly (flushed) and asks for the overnight job, as when Roll leaves the screen.
  func setupRunEnded(_ outcome: SetupOutcome) async {
    setup.runEnded(outcome)
    guard UIApplication.shared.applicationState == .background,
          await !setup.coordinator.isHeld(byOtherThan: "") else { return }
    await stopIndexingForBackground()
  }

  /// Home's setup card: while the model isn't attached, or the first full read is still going.
  var showsSetupCard: Bool {
    guard onboardingComplete, access.canRead else { return false }
    if engine == nil { return true }
    if case .library = setup.progress.stage { return !setup.finishedOnce }
    return false
  }

  // MARK: - Work

  /// Loads the model if nothing is loading it (a retry after a failure: self-healing), then waits for it to attach,
  /// reporting its steps. A load that ends without a model throws its reason. Stopping the wait doesn't stop the load:
  /// the download goes on in the background session, and the rest continues while Roll runs.
  func readyModelForSetup(report: @escaping @Sendable (ModelStep) -> Void) async throws {
    var asked = false
    while engine == nil {
      try Task.checkCancellation()
      if modelTask == nil {
        if asked, case .unavailable(let issue) = modelState { throw Self.block(for: issue) }
        loadModel()
        asked = true
      }
      if let step = setupModelStep { report(step) }
      try await Task.sleep(for: Self.setupPoll)
    }
  }

  /// Photos read (signals and embedding both done, locally) and in all, from the Store. Throws when the Store can't
  /// answer (a cancelled task's reads fail): a guessed 0 of 0 would read as finished.
  func setupLibraryCounts() async throws -> LibraryCounts {
    let total = try await repositories.assetCount()
    let pending = try await indexer.pendingCount(includingEmbedding: true)
    return LibraryCounts(read: total - pending, total: total)
  }

  /// Reads the library through the app's indexing loop (the same loop that runs whenever Roll opens), reporting the
  /// counts until it drains. Up to `setupReadRounds` rounds; a read that still stops short throws.
  func readLibraryForSetup(report: @escaping @Sendable (LibraryCounts) -> Void) async throws {
    for _ in 0..<Self.setupReadRounds {
      guard access.canRead else { throw SetupBlockError(.noPhotoAccess) }
      // Join a loop already running (launch, the embedder's catch-up) rather than queue another round of it.
      if indexTask == nil { startIndexing() }
      repeat {
        report(try await setupLibraryCounts())
        try await Task.sleep(for: Self.setupPoll * 4)
      } while indexTask != nil
      let counts = try await setupLibraryCounts()
      report(counts)
      if counts.isComplete { return }
    }
    let counts = try await setupLibraryCounts()
    throw SetupBlockError(.failed("the library read stopped at \(counts.read) of \(counts.total)"))
  }

  /// The model's step for setup, or nil before the installer has said what it's doing (checking what's installed and
  /// fetching the manifest): reporting `.installing` then would put the bar past the download's share, and the
  /// download's own reports would then sit under the bar's floor, frozen for minutes.
  var setupModelStep: ModelStep? { Self.step(for: modelState, installing: modelInstalling) }

  static func step(for state: ModelState, installing: Bool) -> ModelStep? {
    switch state {
    case .loading(let progress?): .downloading(completedBytes: progress.completedBytes, totalBytes: progress.totalBytes)
    case .loading(nil): installing ? .installing : nil
    case .preparing(let done, let total): .preparing(done: done, total: total)
    case .waiting(.wifi, _): .waiting(.wifi)
    case .waiting(.lowDataMode, _): .waiting(.lowDataMode)
    case .ready, .unavailable: nil
    }
  }

  static func block(for issue: ModelIssue) -> SetupBlockError {
    switch issue {
    case .notEnoughSpace(let required): SetupBlockError(.notEnoughSpace(requiredBytes: required))
    case .notStarted, .notPublished, .failed: SetupBlockError(.failed("the model didn't load: \(issue)"))
    }
  }
}
