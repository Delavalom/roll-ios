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
