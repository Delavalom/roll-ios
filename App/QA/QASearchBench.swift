#if DEBUG
import Foundation
import Indexer
import Ranking

/// DEBUG-only (`-QASearchBench`, with `-QAMetrics`): how long a search over the whole index takes on this phone.
/// Once per launch, when the model is attached and indexing is not running (checked every 10 s, then 30 s of quiet),
/// every preset ranked by embeddings is searched `repeats` times through the app's own engine
/// (`SwipefileEngine.timedCandidates`, 20 results): the query embedding, the read of the candidates and the scoring of
/// every embedded photo. The first call of a launch also loads (or, after an install, compiles) the text function.
/// Logs `search` events: preset name, attempt, milliseconds, results, pool size and the engine's per-step split
/// (`lookup_ms`, `sql_ms`, `decisions_ms`, `pool_ms`, `queries_ms`, `dot_ms`, `score_ms`, `total_ms`; see
/// `SearchTimings`). Read-only; no identifiers.
@MainActor
enum QASearchBench {
  static let presets: [Preset] = [.receipts, .privateStuff, .memes, .screenshots, .blurry]
  static let repeats = 5

  static func start(app: AppModel, log: QAEventLog) {
    Task { @MainActor in
      var quietSince: ContinuousClock.Instant?
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        let idle: [IndexProgress.Phase] = [.idle, .finished, .cancelled, .failed]
        guard app.engine != nil, idle.contains(app.indexProgress.phase) else { quietSince = nil; continue }
        let since = quietSince ?? .now
        quietSince = since
        guard ContinuousClock.now - since >= .seconds(30), let engine = app.engine else { continue }
        await run(engine: engine, log: log)
        await runTyped(engine: engine, log: log)
        return
      }
    }
  }

  private static func run(engine: SwipefileEngine, log: QAEventLog) async {
    log.write("search_bench", ["state": .string("started")])
    for preset in presets {
      let swipefile = preset.swipefile(created: 0)
      for attempt in 1...repeats {
        let start = ContinuousClock.now
        do {
          let (found, timings) = try await engine.timedCandidates(for: swipefile, limit: 20)
          let ms = SearchTimings.ms(ContinuousClock.now - start)
          var fields: [String: QAEventLog.Value] = [
            "preset": .string(preset.rawValue), "attempt": .int(attempt), "ms": .double(ms),
            "results": .int(found.count), "pool": .int(timings.poolCount),
          ]
          // The engine's own split (SearchTimings): sql is 0 when the in-memory rows were current.
          for step in timings.milliseconds { fields["\(step.step)_ms"] = .double(step.ms) }
          log.write("search", fields)
        } catch {
          log.write("search", ["preset": .string(preset.rawValue), "attempt": .int(attempt),
                               "error": .string(String(describing: type(of: error)))])
        }
      }
    }
    log.write("search_bench", ["state": .string("finished")])
  }

  /// Ask Roll's typed queries (`SwipefileEngine.search`: meaning on the query's own scale + words from screenshots and
  /// documents), each `repeats` times. Logs `typed_search`: query, attempt, milliseconds (embedding included), matches,
  /// weaker (folded), and how many were helped by words. The goal is under 100 ms. Counts only, no identifiers.
  static let typedQueries = ["uber receipt", "a dog on the beach", "birthday cake", "boarding pass",
                             "screenshot of a chat", "sunset over the ocean", "wifi password", "xkqzv plorb"]

  private static func runTyped(engine: SwipefileEngine, log: QAEventLog) async {
    for query in typedQueries {
      for attempt in 1...repeats {
        let start = ContinuousClock.now
        do {
          let result = try await engine.search(query)
          log.write("typed_search", [
            "query": .string(query), "attempt": .int(attempt), "ms": .double(SearchTimings.ms(ContinuousClock.now - start)),
            "engine_ms": .double(SearchTimings.ms(result.elapsed)), "matches": .int(result.matches.count),
            "weaker": .int(result.weaker.count), "compared": .int(result.compared),
            "byWords": .int((result.matches + result.weaker).filter { $0.coverage > 0 }.count),
          ])
        } catch {
          log.write("typed_search", ["query": .string(query), "attempt": .int(attempt),
                                     "error": .string(String(describing: type(of: error)))])
        }
      }
    }
  }
}
#endif
