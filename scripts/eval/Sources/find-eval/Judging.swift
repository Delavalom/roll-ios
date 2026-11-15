import CoreGraphics
import FindEvalKit
import Foundation

/// Album members per query slug (union of the query's `albumKey`/`albumKeys`), when specs and an export are given.
/// With `indexed`, only members that have a vector count; the others are counted per slug in `withoutVector`.
struct AlbumMembers {
  var withVector: [String: Set<String>] = [:]
  var withoutVector: [String: Int] = [:]

  init() {}

  init(specs: [URL], export: URL?, indexed: Set<String>?) throws {
    guard !specs.isEmpty, let export else { return }
    let queries = try FindSpec.load(specs).filter { !$0.query.allAlbumKeys.isEmpty }
    guard !queries.isEmpty else { return }
    let members = Albums.members(try JSONLines.decode(ExportAsset.self, from: export))
    for q in queries {
      let split = try Albums.split(keys: q.query.allAlbumKeys, members: members, indexed: indexed)
      withVector[q.slug] = split.withVector
      withoutVector[q.slug] = split.withoutVector
    }
  }
}

/// For each `pool/<slug>.json` (only the specs' queries when given): the pooled ids without a label (and not album
/// members), as numbered contact sheets `<out>/<slug>/sheet-NN.png` + `manifest.json`. Old sheets of that query are
/// removed first, so apply the judgments of one round before rendering the next.
func sheetsCommand(pool: URL, thumbs: URL, labels: URL, out: URL, specs: [URL], export: URL?) throws {
  let fm = FileManager.default
  let thumbIndex = try ThumbIndex(folder: thumbs)
  let only = specs.isEmpty ? nil : Set(try FindSpec.load(specs).map(\.slug))
  let albums = try AlbumMembers(specs: specs, export: export, indexed: nil).withVector
  let files = try fm.contentsOfDirectory(atPath: pool.path).filter { $0.hasSuffix(".json") }.sorted()
  var sheets = 0, tiles = 0, missing = 0
  for file in files {
    let p = try JSONOut.read(PoolFile.self, from: pool.appending(path: file))
    if let only, !only.contains(p.slug) { continue }
    let judged = try Labels.load(labels, slug: p.slug).judged.union(albums[p.slug] ?? [])
    let todo = p.ids.filter { !judged.contains($0) }
    let manifest = SheetManifest.plan(slug: p.slug, query: p.query, ids: todo)
    let dir = out.appending(path: p.slug)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for old in try fm.contentsOfDirectory(atPath: dir.path) where old.hasPrefix("sheet-") && old.hasSuffix(".png") {
      try fm.removeItem(at: dir.appending(path: old))
    }
    for sheet in manifest.sheets {
      let images = sheet.tiles.map { tile -> CGImage? in
        let image = thumbIndex.url(for: tile.id).flatMap(SheetRenderer.loadImage)
        if image == nil { missing += 1 }
        return image
      }
      try SheetRenderer.render(images, to: dir.appending(path: sheet.file))
      sheets += 1; tiles += sheet.tiles.count
    }
    try JSONOut.write(manifest, to: dir.appending(path: "manifest.json"))
  }
  print("\(sheets) sheets, \(tiles) tiles (\(missing) missing thumbnails)")
}

/// Judge output → `labels/<slug>.json`, merged with the labels already there (a new verdict replaces an old one) and
/// album members always relevant. With specs and an export, every album-derived query gets its members even without
/// judgments; with `poolRoot` (its `indexed-ids.txt`) only members that have a vector.
func applyJudgmentsCommand(sheets: URL, judgments: URL?, labels: URL, specs: [URL], export: URL?,
                           poolRoot: URL?) throws {
  let judged = try judgments.map { try JSONOut.read(Judgments.self, from: $0) } ?? [:]
  let indexed = try poolRoot.flatMap { try IndexedIds.read($0) }
  let albums = try AlbumMembers(specs: specs, export: export, indexed: indexed).withVector
  try FileManager.default.createDirectory(at: labels, withIntermediateDirectories: true)
  for slug in Set(judged.keys).union(albums.keys).sorted() {
    var verdicts: [String: Labels.Verdict] = [:]
    if let bySheet = judged[slug] {
      let manifest = try JSONOut.read(SheetManifest.self, from: sheets.appending(path: slug).appending(path: "manifest.json"))
      verdicts = try JudgmentApplication.verdicts(manifest: manifest, judged: bySheet)
    }
    let merged = try Labels.load(labels, slug: slug).merged(with: verdicts, alwaysRelevant: albums[slug] ?? [])
    try JSONOut.write(merged, to: labels.appending(path: "\(slug).json"))
    print("\(albums[slug] == nil ? slug : "album query"): +\(verdicts.count) verdicts -> \(merged.relevant.count) "
          + "relevant, \(merged.notRelevant.count) not, \(merged.unsure.count) unsure")
  }
}

/// Per query and variant, metrics against the labels (+ album members), identifier-free: `<out>/summary.json` and
/// `<out>/queries/<slug or private-NN>.json`.
///
/// Only ids with a vector count (`<pool root>/indexed-ids.txt`, from `pool`): labels and album members outside the
/// index are left out, and album members without a vector are reported per query.
func scoreCommand(poolRoot: URL, labels: URL, specs: [URL], export: URL?, out: URL) throws {
  let queries = try FindSpec.load(specs)
  let indexed = try IndexedIds.read(poolRoot)
  if indexed == nil { print("no indexed-ids.txt in the pool root: counting every labelled id") }
  let albumSet = try AlbumMembers(specs: specs, export: export, indexed: indexed)
  let albums = albumSet.withVector
  let dirs = try Pooling.variantDirectories(in: poolRoot)
  var evidence: [(file: String, QueryEvidence)] = []
  var privateNumber = 0
  for q in queries {
    let l = try Labels.load(labels, slug: q.slug).restricted(to: indexed)
    let album = albums[q.slug] ?? []
    var scores: [String: VariantScore] = [:]
    for d in dirs {
      let url = poolRoot.appending(path: d).appending(path: "\(q.slug).json")
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let run = try JSONOut.read(VariantRun.self, from: url)
      scores[d] = VariantScore.score(run: run, labels: l, extraRelevant: album, expect: q.query.expect)
    }
    let name: String
    if q.isPrivate { privateNumber += 1; name = String(format: "private-%02d", privateNumber) } else { name = q.name }
    let file = q.isPrivate ? name : q.slug
    evidence.append((file, QueryEvidence(
      name: name, group: q.query.group, expect: q.query.expect,
      relevantKnown: Set(l.relevant).union(album).count, judged: l.judged.union(album).count,
      albumMembers: q.query.allAlbumKeys.isEmpty ? nil : album.count,
      albumMembersWithoutVector: q.query.allAlbumKeys.isEmpty ? nil : albumSet.withoutVector[q.slug] ?? 0,
      variants: scores)))
  }
  let summary = FindSummary.make(evidence.map(\.1), variants: dirs)
  try JSONOut.write(summary, to: out.appending(path: "summary.json"))
  for (file, e) in evidence { try JSONOut.write(e, to: out.appending(path: "queries").appending(path: "\(file).json")) }
  for v in dirs {
    guard let m = summary.overall[v] else { continue }
    func f(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "-" }
    print("\(v): P@10 \(f(m.pAt10)) P@20 \(f(m.pAt20)) nDCG@20 \(f(m.ndcgAt20)) R@100 \(f(m.recallAt100)) "
          + "median strong \(f(m.medianStrong)) nonsense refused \(f(m.refusedShare))")
  }
}
