import Foundation
import Ranking
import Store
import Testing

/// `ROLL_BENCH=1` only: times each step of `SwipefileEngine.candidates` (20 cards) over `SearchBenchWorld` (29,681
/// embedded rows at 256 dimensions, on-disk WAL database like the app). Per preset: a first call (prompt cache and
/// pool caches cold), then 5 warm calls; then one call right after a swipe (a decision write) and one right after an asset write, to show
/// what invalidation costs. `ROLL_BENCH_OUT` names a JSON file to write; the summary is printed either way.
/// Run in both configurations: the phone QA builds are Debug (`-Onone`), the App Store build is Release:
/// `ROLL_BENCH=1 swift test --filter SearchSpeedBench`, and the same with `-c release -Xswiftc -enable-testing`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ROLL_BENCH"] == "1"))
struct SearchSpeedBench {
  static let presets: [Preset] = [.receipts, .privateStuff, .memes, .screenshots, .blurry]
  static let runs = 5

  @Test func candidatesStepByStep() async throws {
    let world = try await SearchBenchWorld.make()
    defer { world.cleanUp() }
    var out: [String: Any] = [:]
    #if DEBUG
    out["configuration"] = "debug (-Onone)"
    #else
    out["configuration"] = "release (-O)"
    #endif
    out["machine"] = Self.cpu()
    out["rows"] = SearchBenchWorld.rows
    out["embedded"] = SearchBenchWorld.rows - SearchBenchWorld.unembedded
    out["dimensions"] = SearchBenchWorld.dimensions
    out["limit"] = 20
    var presets: [[String: Any]] = []
    for (n, preset) in Self.presets.enumerated() {
      let sf = preset.swipefile(created: 0)
      // The first call embeds the prompts (stub: no model cost) and fills whatever the engine caches.
      let firstCall = try await world.engine.timedCandidates(for: sf).timings
      var runs: [SearchTimings] = []
      var results = 0
      for _ in 0..<Self.runs {
        let (cards, t) = try await world.engine.timedCandidates(for: sf)
        runs.append(t)
        results = cards.count
      }
      // A swipe writes a decision; an indexing flush or a library change writes asset rows.
      let first = try #require(try await world.engine.candidates(for: sf).first)
      try await world.engine.record(swipefileId: sf.id, assetId: first.id, verdict: .keep)
      let afterSwipe = try await world.engine.timedCandidates(for: sf).timings
      try await world.repo.markEmbedded(ids: [world.ids[1_000 + n]])
      let afterAssetWrite = try await world.engine.timedCandidates(for: sf).timings
      let m = Self.median(runs)
      presets.append([
        "preset": preset.rawValue, "filter": preset.filter == .none ? "none" : "\(preset.filter)",
        "prompts": preset.prompts.count, "poolCount": runs[0].poolCount, "results": results,
        "firstCallMs": Self.dict(firstCall), "warmMedianMs": m, "warmMinMs": Self.minimum(runs),
        "warmRunsMs": runs.map(Self.dict),
        "afterSwipeMs": Self.dict(afterSwipe), "afterAssetWriteMs": Self.dict(afterAssetWrite),
      ])
      let steps = SearchTimings().milliseconds.map { "\($0.step)=\(String(format: "%.2f", m[$0.step] ?? 0))" }
      print("bench \(preset.rawValue) pool=\(runs[0].poolCount) results=\(results) \(steps.joined(separator: " "))"
            + " afterSwipe=\(String(format: "%.2f", SearchTimings.ms(afterSwipe.total)))"
            + " afterAssetWrite=\(String(format: "%.2f", SearchTimings.ms(afterAssetWrite.total)))")
    }
    out["presets"] = presets
    if let path = ProcessInfo.processInfo.environment["ROLL_BENCH_OUT"], !path.isEmpty {
      let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: path))
    }
  }

  /// Typed search (Ask Roll's `SwipefileEngine.search`) over the same world: a first call, then the median of 10 warm
  /// calls per query (stub query embedding, so this is the store read, `dotAll`, gating and ranking).
  @Test func typedSearch() async throws {
    let world = try await SearchBenchWorld.make()
    defer { world.cleanUp() }
    let queries = ["receipts and invoices", "screenshots of chats", "a dog on the beach", "zxqv blorp"]
    let clock = ContinuousClock()
    for query in queries {
      let firstStart = clock.now
      _ = try await world.engine.search(query)
      let first = SearchTimings.ms(clock.now - firstStart)
      var warm: [Double] = []
      var count = 0
      for _ in 0..<10 {
        let start = clock.now
        let result = try await world.engine.search(query)
        warm.append(SearchTimings.ms(clock.now - start))
        count = result.matches.count + result.weaker.count
      }
      warm.sort()
      print("bench search \"\(query)\" results=\(count) first=\(String(format: "%.2f", first))"
            + " warmMedian=\(String(format: "%.2f", warm[warm.count / 2])) warmMin=\(String(format: "%.2f", warm[0]))")
    }
    // Find variants over the same library (V2 parses the query; V3 groups by event, with no events stored here; "all"
    // adds seeds, tags, a relative cut and a nothing-found test).
    let seeds = try await world.engine.search("a dog on the beach").matches.prefix(3).map(\.id)
    var all = FindConfig.v3
    all.understanding = true
    all.tags = true
    all.relativeCut = 0.6
    all.nothingFound = NothingFoundTest(minTopGap: 1)
    let variants: [(String, FindConfig)] = [("v0", .v0), ("v1", .v1), ("v2", .v2), ("v3", .v3), ("all", all)]
    for (name, config) in variants {
      let query = "a dog on the beach"
      let picked = name == "all" ? Array(seeds) : []
      _ = try await world.engine.find(query, config: config, seeds: picked)
      var warm: [Double] = []
      for _ in 0..<10 {
        let start = clock.now
        _ = try await world.engine.find(query, config: config, seeds: picked)
        warm.append(SearchTimings.ms(clock.now - start))
      }
      warm.sort()
      print("bench find \(name) warmMedian=\(String(format: "%.2f", warm[warm.count / 2]))"
            + " warmMin=\(String(format: "%.2f", warm[0]))")
    }
  }

  /// Tags (V4) over the same world: every photo gets 3–10 scene labels in the store (the tag pass keeps >= 0.1, top 10),
  /// then `find` with tags off, with tags on, and with `FindConfig.shipping`: a first call (reads and folds the labels
  /// into a `TagIndex`), the median of 10 warm calls, and `TagIndex.coverage` alone. Tags should add < 5 ms warm.
  @Test func typedSearchWithTags() async throws {
    let world = try await SearchBenchWorld.make()
    defer { world.cleanUp() }
    let vocabulary = ["sport", "ball", "grass", "beach", "sand", "ocean", "dog", "pet", "cake", "outdoor", "sky",
                      "food", "dessert", "snow", "stage", "people", "adult", "structure", "plant", "document", "text",
                      "screenshot", "night_sky", "car", "vehicle", "wedding_dress", "candle", "furniture", "child"]
    var g = SeededRNG(seed: 4)
    var items: [TagFields] = []
    for id in world.ids {
      let labels = (0..<Int.random(in: 3...10, using: &g)).map { _ in
        TagLabel(label: vocabulary.randomElement(using: &g)!, confidence: Double.random(in: 0.1...0.95, using: &g))
      }
      items.append(TagFields(id: id, labels: labels, revision: "bench", side: 360))
    }
    for start in stride(from: 0, to: items.count, by: 2_000) {
      try await world.repo.commitTags(Array(items[start..<min(start + 2_000, items.count)]))
    }
    let clock = ContinuousClock()
    let query = "a dog on the beach"
    var tagsOn = FindConfig.v0
    tagsOn.tags = true
    for (name, config) in [("v0", FindConfig.v0), ("v0+tags", tagsOn), ("shipping", FindConfig.shipping)] {
      let firstStart = clock.now
      _ = try await world.engine.find(query, config: config)
      let first = SearchTimings.ms(clock.now - firstStart)
      var warm: [Double] = []
      for _ in 0..<10 {
        let start = clock.now
        _ = try await world.engine.find(query, config: config)
        warm.append(SearchTimings.ms(clock.now - start))
      }
      warm.sort()
      print("bench find+tags \(name) first=\(String(format: "%.2f", first))"
            + " warmMedian=\(String(format: "%.2f", warm[warm.count / 2])) warmMin=\(String(format: "%.2f", warm[0]))")
    }
    let index = TagIndex(labels: try await world.repo.tagLabels(minConfidence: 0.3))
    var times: [Double] = []
    for _ in 0..<10 {
      let start = clock.now
      _ = index.coverage(queryTerms: SearchTerms.queryTerms(query))
      times.append(SearchTimings.ms(clock.now - start))
    }
    times.sort()
    print("bench tagIndex photos=\(index.photoCount) coverageMedian=\(String(format: "%.3f", times[times.count / 2]))")
  }

  static func dict(_ t: SearchTimings) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: t.milliseconds.map { ($0.step, ($0.ms * 1000).rounded() / 1000) })
  }

  /// Per-step minimum of `runs` (less sensitive to other work on the machine).
  static func minimum(_ runs: [SearchTimings]) -> [String: Double] {
    var out: [String: Double] = [:]
    for (i, step) in SearchTimings().milliseconds.map(\.step).enumerated() {
      out[step] = ((runs.map { $0.milliseconds[i].ms }.min() ?? 0) * 1000).rounded() / 1000
    }
    return out
  }

  static func cpu() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// Per-step median of `runs`.
  static func median(_ runs: [SearchTimings]) -> [String: Double] {
    var out: [String: Double] = [:]
    for (i, step) in SearchTimings().milliseconds.map(\.step).enumerated() {
      let sorted = runs.map { $0.milliseconds[i].ms }.sorted()
      out[step] = (sorted[sorted.count / 2] * 1000).rounded() / 1000
    }
    return out
  }
}
