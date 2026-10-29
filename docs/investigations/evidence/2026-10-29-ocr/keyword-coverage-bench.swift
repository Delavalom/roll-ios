import Foundation
import Testing
@testable import Store

// keywordCoverage latency over 6,300 texts in a 30k-asset database (evidence for docs/investigations/2026-10-29-ocr.md).
// To rerun: copy into Packages/RollCore/Tests/StoreTests and `swift test --filter ZZCoverageBench`; it writes
// /tmp/coverage-bench.json. Not kept in the test suite (it takes seconds and writes outside the package).
struct ZZCoverageBench {
  @Test func bench() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cov-\(UUID()).sqlite")
    let db = try AppDatabase.open(at: url)
    let repo = Repositories(db)
    var rng = SystemRandomNumberGenerator()
    let vocab = (0..<5000).map { i in "w" + String(i, radix: 36) + (i % 7 == 0 ? "receipt" : "") }
    let n = 6300
    try await repo.replaceAssetsForTesting((0..<n).map { Fixtures.asset("a\($0)", created: Double($0)) }
      + (0..<23_700).map { Fixtures.asset("p\($0)", created: Double($0)) })
    var items: [TextFields] = []
    for i in 0..<n {
      let words = (0..<60).map { _ in vocab[Int.random(in: 0..<vocab.count, using: &rng)] } + ["uber", "total", String(i)]
      items.append(TextFields(id: "a\(i)", text: words.joined(separator: " "), revision: "r", side: 960))
    }
    let t0 = Date()
    for s in stride(from: 0, to: n, by: 20) { try await repo.commitText(Array(items[s..<min(s + 20, n)])) }
    let commitMs = Date().timeIntervalSince(t0) * 1000
    var out: [String: Any] = ["texts": n, "assets": n + 23_700, "termsPerText": 63,
                              "commitAllMsIn20s": commitMs.rounded()]
    let queries: [(String, [String])] = [
      ("1 rare term", ["w1a"]), ("1 term in every text", ["uber"]), ("3 terms", ["uber", "w2b", "123"]),
      ("prefix fallback", ["w0rec"]), ("6 terms", ["uber", "total", "w1", "w2", "w3", "w4"]), ("no match", ["zzzz"]),
    ]
    for (name, q) in queries {
      var ms: [Double] = []
      var size = 0
      for _ in 0..<7 {
        let t = Date()
        size = try await repo.keywordCoverage(terms: q).count
        ms.append(Date().timeIntervalSince(t) * 1000)
      }
      out[name] = ["medianMs": (ms.sorted()[3] * 10).rounded() / 10, "results": size]
    }
    out["dbBytes"] = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: "/tmp/coverage-bench.json"))
  }
}
