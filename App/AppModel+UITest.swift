#if DEBUG
import Foundation
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
  }
}
#endif
