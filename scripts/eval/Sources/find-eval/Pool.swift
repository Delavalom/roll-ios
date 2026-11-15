import FindEvalKit
import Foundation

struct PoolOptions {
  var db: URL
  var index: URL
  var qvecs: URL
  var specs: [URL]
  var export: URL?
  var vision: URL?
  var labels: URL?
  var variants: [String]
  var k: Int
  var out: URL
}

/// Runs each variant on each query and writes `<out>/<variant>/<slug>.json` (`VariantRun`: the top
/// `max(k, 100)` ids and the full answer size), then rebuilds `<out>/pool/<slug>.json` from **every** variant folder
/// in `out` (so a later round with new variants adds to the pool), `<out>/thumb-request.txt` (every pooled id of
/// every pool file, one per line) and `<out>/indexed-ids.txt` (every id with a vector, for `score`). All private.
/// Prints counts only (private queries by number).
func poolCommand(_ o: PoolOptions) async throws {
  guard o.k > 0 else { throw FindSpec.Invalid("--k must be positive") }
  let queries = try FindSpec.load(o.specs)
  let variants = try Variants.named(o.variants)
  let clock = ContinuousClock()
  var mark = clock.now
  let library = try await FindLibrary(db: o.db, index: o.index, qvecs: o.qvecs, export: o.export, vision: o.vision,
                                      labels: o.labels)
  let textRows = try await library.textRows()
  print("library: \(library.ids.count) vectors, \(library.poolCount) in the search pool, \(textRows) rows of words, "
        + "export \(library.export.count), vision \(library.vision.count); loaded in \(clock.now - mark)")

  let keep = max(o.k, VariantRun.keepAtLeast)
  var privateNumber = 0
  for q in queries {
    let label: String
    if q.isPrivate { privateNumber += 1; label = String(format: "private-%02d", privateNumber) } else { label = q.slug }
    var line = "\(label):"
    for v in variants {
      mark = clock.now
      let answer = try await v.answer(q, in: library)
      let elapsed = clock.now - mark
      let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
      let run = VariantRun(variant: v.name, slug: q.slug, query: q.text, k: o.k, top: Array(answer.ranked.prefix(keep)),
                           strong: answer.strong.count, weaker: answer.weaker.count, elapsedMs: ms, notes: answer.notes)
      try JSONOut.write(run, to: o.out.appending(path: v.name).appending(path: "\(q.slug).json"))
      line += String(format: " %@ %d strong + %d weaker (%.0f ms)", v.name, run.strong, run.weaker, ms)
    }
    print(line)
  }

  try IndexedIds.write(library.ids, poolRoot: o.out)
  if !library.export.isEmpty {
    let members = Albums.members(Array(library.export.values))
    let indexed = Set(library.ids)
    var privateAlbum = 0
    for q in queries where !q.query.allAlbumKeys.isEmpty {
      privateAlbum += 1
      let split = try Albums.split(keys: q.query.allAlbumKeys, members: members, indexed: indexed)
      print(String(format: "album query %02d: %d members with a vector, %d without", privateAlbum,
                   split.withVector.count, split.withoutVector))
    }
  }
  let pools = try rebuildPools(root: o.out, queries: queries, k: o.k)
  let all = try writeThumbRequest(root: o.out)
  print("pooled \(pools.map(\.ids.count).reduce(0, +)) ids over \(pools.count) queries (\(all) distinct in "
        + "thumb-request.txt)")
}

/// `pool/<slug>.json` for each query from every variant folder that answered it (variant folders in name order).
func rebuildPools(root: URL, queries: [ResolvedQuery], k: Int) throws -> [PoolFile] {
  let dirs = try Pooling.variantDirectories(in: root)
  var pools: [PoolFile] = []
  for q in queries {
    var names: [String] = [], runs: [[String]] = []
    for d in dirs {
      let url = root.appending(path: d).appending(path: "\(q.slug).json")
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      names.append(d)
      runs.append(try JSONOut.read(VariantRun.self, from: url).top)
    }
    let pool = PoolFile(slug: q.slug, query: q.text, group: q.query.group, expect: q.query.expect, k: k,
                        variants: names, ids: Pooling.union(runs, k: k))
    try JSONOut.write(pool, to: root.appending(path: "pool").appending(path: "\(q.slug).json"))
    pools.append(pool)
  }
  return pools
}

/// Every id of every `pool/*.json`, sorted, one per line. Returns how many.
func writeThumbRequest(root: URL) throws -> Int {
  let dir = root.appending(path: "pool")
  let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
  let pools = try files.map { try JSONOut.read(PoolFile.self, from: dir.appending(path: $0)) }
  let ids = Pooling.allIds(pools)
  try (ids.joined(separator: "\n") + (ids.isEmpty ? "" : "\n")).write(to: root.appending(path: "thumb-request.txt"),
                                                                      atomically: true, encoding: .utf8)
  return ids.count
}
