#if DEBUG
import Embedding
import Foundation
import ModelInstall
import Store

extension AppModel {
  /// `-UITestResetState`: a fresh install's state, without reinstalling, except that an unfinished squish survives
  /// (`AppDatabase.resetForUITests`): its journal is kept so the recovery banner and the copy exclusions still work.
  static func resetStateForUITests(database url: URL, defaults: UserDefaults) throws {
    switch try AppDatabase.resetForUITests(at: url) {
    case .removedEverything:
      break
    case .keptSquishJournal(let open):
      QARuntime.logger.notice("-UITestResetState kept the squish journal: \(open) unfinished squishes")
      QARuntime.shared?.log.write("ui_test_reset", ["keptSquishJournal": .bool(true), "openSquishes": .int(open)])
    }
    defaults.removeObject(forKey: onboardingKey)
    defaults.removeObject(forKey: SwipeHint.seenKey)
    for key in [SetupModel.startedKey, SetupModel.finishedOnceKey, SetupModel.notifyKey, SetupModel.notifiedKey] {
      defaults.removeObject(forKey: key)
    }
  }
}

/// `-UITestHoldModel`: a model download that reports a third done and never finishes, so the setup card and screen
/// can be tested in a stable state (SetupFlowTests).
struct HeldLoader: EmbedderLoader {
  func load(allowCellular: Bool, report: @escaping @Sendable (InstallStep) -> Void) async throws -> any Embedder {
    report(.downloading(completedBytes: 120_000_000, totalBytes: 359_000_000))
    while true { try await Task.sleep(for: .seconds(3600)) }
  }
}
#endif
