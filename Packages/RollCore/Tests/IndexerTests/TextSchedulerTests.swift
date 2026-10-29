import Foundation
import Library
import Store
import Synchronization
import Testing
@testable import Indexer

struct TextBackgroundHandOffTests {
  @Test func goingToTheBackgroundStopsTheTextPassAndSchedulesWhenWordsAreLeft() async throws {
    let shots = (0..<3).map { i in
      AssetSnapshot(id: FakeLibrary.id(i), mediaType: MediaKind.image, subtypes: MediaSubtype.screenshot,
                    created: Double(10 - i), pixelW: 1170, pixelH: 2532)
    }
    try await Harness.with(library: FakeLibrary(assets: shots)) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      try await indexer.run()
      let fake = FakeReader()
      let entered = Mutex(false)
      fake.onRecognize.withLock { $0 = { _ in
        entered.withLock { $0 = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
      } }
      let text = TextIndexer(library: h.library, reader: fake, repo: h.repo,
                             thermal: ThermalGate(provider: FakeThermal(), pollInterval: .milliseconds(1)))
      let foreground = Task { try await text.run() }
      try await Harness.waitUntil { entered.withLock { $0 } }
      let scheduled = Mutex(0)
      await IndexScheduler.prepareForBackground(indexer: indexer, text: text) { scheduled.withLock { $0 += 1 } }
      await #expect(throws: CancellationError.self) { try await foreground.value }
      #expect(scheduled.withLock { $0 } == 1, "3 images are still unread")
    }
  }
}

/// The background task runs the text pass after the index run (`IndexScheduler.perform(indexer:text:...)`).
struct TextSchedulerTests {
  /// `count` screenshots, newest first.
  private func screenshots(_ count: Int) -> FakeLibrary {
    FakeLibrary(assets: (0..<count).map { i in
      AssetSnapshot(id: FakeLibrary.id(i), mediaType: MediaKind.image, subtypes: MediaSubtype.screenshot,
                    created: Double(1_000_000 - i), pixelW: 1170, pixelH: 2532)
    })
  }

  private func reader(_ h: Harness, _ reader: FakeReader) -> TextIndexer {
    TextIndexer(library: h.library, reader: reader, repo: h.repo,
                thermal: ThermalGate(provider: FakeThermal(), pollInterval: .milliseconds(1), pausesAt: .fair))
  }

  @Test func aBackgroundRunReadsTheWordsAfterIndexing() async throws {
    try await Harness.with(library: screenshots(5)) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let text = reader(h, FakeReader())
      let bg = FakeBackgroundTask()
      await IndexScheduler.perform(indexer: { indexer }, text: { text }, setExpirationHandler: bg.setExpiration,
                                   reschedule: bg.reschedule, complete: bg.complete).value
      #expect(bg.completed == [true])
      #expect(bg.reschedules == 0)
      #expect(try await h.count("embedded = 1 AND signalsDone = 1") == 5)
      #expect(try await h.repo.keywordCoverage(terms: ["uber"]).count == 5)
    }
  }

  @Test func expiringDuringTheTextPassKeepsWhatWasReadAndReschedules() async throws {
    try await Harness.with(library: screenshots(5)) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let fake = FakeReader()
      let bg = FakeBackgroundTask()
      fake.onRecognize.withLock { $0 = { n in
        guard n == 3 else { return }
        bg.expire()
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
      } }
      let text = reader(h, fake)
      await IndexScheduler.perform(indexer: { indexer }, text: { text }, setExpirationHandler: bg.setExpiration,
                                   reschedule: bg.reschedule, complete: bg.complete).value
      #expect(bg.completed == [false])
      #expect(bg.reschedules == 1, "3 images are still unread")
      #expect(try await h.repo.keywordCoverage(terms: ["uber"]).count == 2)
    }
  }

  @Test func withoutATextPassNothingIsRead() async throws {
    try await Harness.with(library: screenshots(2)) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      let bg = FakeBackgroundTask()
      await IndexScheduler.perform(indexer: { indexer }, setExpirationHandler: bg.setExpiration,
                                   reschedule: bg.reschedule, complete: bg.complete).value
      #expect(bg.completed == [true])
      #expect(try await h.repo.keywordCoverage(terms: ["uber"]).isEmpty)
    }
  }
}
