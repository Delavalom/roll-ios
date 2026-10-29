import Foundation
import Indexer
import Ranking
import Store

// MARK: - After indexing drains: words in images, warm piles

extension AppModel {
  /// Once the photo pass has drained: reads the words of gated images (screenshots and documents, `TextGate`) that
  /// have none yet, then warms the preset piles' in-memory rows so the first pile opened skips its database read. Both
  /// are cheap to call again: the text pass shares a run already in flight, and `TextIndexer` pauses from thermal
  /// `.fair`. A new indexing loop (`startIndexing`) or a taste scan cancels the text pass; it resumes on the next drain.
  func afterIndexDrained() {
    guard environment.isLive, access.canRead else { return }
    let text = textIndexer, engine = engine, generation = textGeneration
    Task(priority: .utility) { [weak self] in
      if let engine { try? await engine.preparePools(for: Preset.allCases) }
      // Indexing restarted or the app went to the background meanwhile: their cancel came before this run existed.
      guard let self, self.textGeneration == generation else { return }
      #if DEBUG
      QARuntime.shared?.log.write("text_pass", ["state": .string("started")])
      let start = ContinuousClock.now
      #endif
      let report = try? await text.run()
      #if DEBUG
      let ms = SearchTimings.ms(ContinuousClock.now - start)
      if let report {
        QARuntime.shared?.log.write("text_pass", [
          "state": .string("finished"), "ms": .double(ms), "read": .int(report.read),
          "withWords": .int(report.withWords), "unread": .int(report.unread), "failed": .int(report.failed),
        ])
      } else {
        QARuntime.shared?.log.write("text_pass", ["state": .string("stopped"), "ms": .double(ms)])
      }
      #endif
      if report != nil { self.bumpLibrary() }
    }
  }
}
