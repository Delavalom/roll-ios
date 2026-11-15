import Foundation
import Indexer
import Ranking
import Store

// MARK: - After indexing drains: words in images, scene tags, warm piles

extension AppModel {
  /// Once the photo pass has drained: reads the words of gated images (screenshots and documents, `TextGate`) that
  /// have none yet, then labels photos for Find's tags (`TagIndexer`, when `FindConfig.shipping.tags`), and warms the
  /// preset piles' in-memory rows so the first pile opened skips its database read. All are cheap to call again: the
  /// passes share a run already in flight and pause from thermal `.fair`. A new indexing loop (`startIndexing`) or a
  /// taste scan cancels both passes; they resume on the next drain (each photo is read once per revision).
  func afterIndexDrained() {
    guard environment.isLive, access.canRead else { return }
    let text = textIndexer, tags = tagIndexer, engine = engine, generation = textGeneration
    Task(priority: .utility) { [weak self] in
      if let engine { try? await engine.preparePools(for: Preset.allCases) }
      // Events, then living albums' new photos (offered on Home, never added silently).
      await self?.living.refresh(engine: engine)
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
      // Scene tags last: search reads them again after each commit (`RankingChanges.tagGeneration`), no bump needed.
      guard FindConfig.shipping.tags, report != nil, self.textGeneration == generation else { return }
      #if DEBUG
      QARuntime.shared?.log.write("tag_pass", ["state": .string("started")])
      let tagStart = ContinuousClock.now
      #endif
      let tagged = try? await tags.run()
      #if DEBUG
      let tagMs = SearchTimings.ms(ContinuousClock.now - tagStart)
      if let tagged {
        QARuntime.shared?.log.write("tag_pass", [
          "state": .string("finished"), "ms": .double(tagMs), "read": .int(tagged.read),
          "tagged": .int(tagged.tagged), "unread": .int(tagged.unread), "failed": .int(tagged.failed),
        ])
      } else {
        QARuntime.shared?.log.write("tag_pass", ["state": .string("stopped"), "ms": .double(tagMs)])
      }
      #endif
      _ = tagged
    }
  }

  /// Stops the text and tag passes (each commits what it read); the photo pass or a taste scan goes first.
  func cancelAfterIndexPasses() async {
    await textIndexer.cancel()
    await tagIndexer.cancel()
  }
}
