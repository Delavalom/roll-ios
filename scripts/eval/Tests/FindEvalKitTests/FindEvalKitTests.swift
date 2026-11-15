import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FindEvalKit

struct MetricTests {
  private let ranked = ["a", "b", "c", "d", "e"]

  @Test func precisionDividesByKEvenWhenTheAnswerIsShort() {
    #expect(FindMetrics.precision(at: 2, ranked: ranked, relevant: ["a", "c"]) == 0.5)
    #expect(FindMetrics.precision(at: 10, ranked: ranked, relevant: ["a", "c"]) == 0.2)
    #expect(FindMetrics.precision(at: 10, ranked: [], relevant: ["a"]) == 0)
  }

  @Test func unjudgedCountsResultsWithNoLabel() {
    #expect(FindMetrics.unjudged(at: 3, ranked: ranked, judged: ["a", "z"]) == 2)
    #expect(FindMetrics.unjudged(at: 10, ranked: ranked, judged: []) == 5)
  }

  @Test func ndcgIsOneForAPerfectTopAndUsesBinaryGain() throws {
    #expect(FindMetrics.ndcg(at: 20, ranked: ranked, relevant: ["a", "b"]) == 1)
    // One relevant at rank 2 of one known: (1/log2 3) / (1/log2 2).
    let v = try #require(FindMetrics.ndcg(at: 20, ranked: ranked, relevant: ["b"]))
    #expect(abs(v - 1 / log2(3.0)) < 1e-12)
    // Relevant known but not retrieved counts in the ideal: 2 known, 1 found at rank 1.
    let w = try #require(FindMetrics.ndcg(at: 20, ranked: ranked, relevant: ["a", "zz"]))
    #expect(abs(w - 1 / (1 + 1 / log2(3.0))) < 1e-12)
    #expect(FindMetrics.ndcg(at: 20, ranked: ranked, relevant: []) == nil)
  }

  @Test func ndcgIdealIsCappedAtK() throws {
    let relevant = Set((0..<30).map { "r\($0)" })
    let perfect = (0..<20).map { "r\($0)" }
    #expect(try #require(FindMetrics.ndcg(at: 20, ranked: perfect, relevant: relevant)) == 1)
  }

  @Test func pooledRecallIsAgainstEveryKnownRelevantId() {
    let ranked = (0..<150).map { "x\($0)" }
    // x10 and x120 known relevant; only x10 is in the first 100.
    #expect(FindMetrics.recall(at: 100, ranked: ranked, relevant: ["x10", "x120"]) == 0.5)
    #expect(FindMetrics.recall(at: 100, ranked: ranked, relevant: []) == nil)
  }

  @Test func variantScoreCountsUnsureAsNotRelevantAndAlbumsAsRelevant() throws {
    let run = VariantRun(variant: "V0", slug: "q", query: "q", k: 50, top: ["a", "b", "c", "d"], strong: 3, weaker: 1,
                         elapsedMs: 2)
    let labels = Labels(relevant: ["a"], notRelevant: ["b"], unsure: ["c"])
    let s = VariantScore.score(run: run, labels: labels, extraRelevant: ["d"], expect: .matches)
    #expect(s.pAt10 == 0.2)  // a + d
    #expect(s.unjudgedAt10 == 0)
    #expect(s.unsureAt20 == 1)
    #expect(s.falseRefusal == false)
    #expect(s.refused == nil)
    #expect(s.recallAt100 == 1)
  }

  @Test func nonsenseIsGradedOnRefusalOnly() {
    let empty = VariantRun(variant: "V0", slug: "n", query: "n", k: 50, top: ["a"], strong: 0, weaker: 1, elapsedMs: 1)
    let s = VariantScore.score(run: empty, labels: Labels(), expect: .nothing)
    #expect(s.refused == true)
    #expect(s.pAt10 == nil && s.ndcgAt20 == nil && s.falseRefusal == nil)
    let loud = VariantRun(variant: "V0", slug: "n", query: "n", k: 50, top: ["a"], strong: 1, weaker: 0, elapsedMs: 1)
    #expect(VariantScore.score(run: loud, labels: Labels(), expect: .nothing).refused == false)
  }

  @Test func groupMeansUseOnlyDefinedValues() throws {
    func score(p: Double?, refused: Bool?, strong: Int) -> VariantScore {
      VariantScore(pAt10: p, pAt20: p, pAt50: p, unjudgedAt10: 0, unjudgedAt20: 2, unjudgedAt50: 0, unsureAt20: 0,
                   ndcgAt20: p, recallAt100: p, strong: strong, weaker: 0, refused: refused,
                   falseRefusal: refused == nil ? strong == 0 : nil, elapsedMs: 4)
    }
    let m = GroupMeans.of([score(p: 0.5, refused: nil, strong: 10), score(p: 1, refused: nil, strong: 0),
                           score(p: nil, refused: true, strong: 0), score(p: nil, refused: false, strong: 7)])
    #expect(m.queries == 4)
    #expect(m.pAt10 == 0.75)
    #expect(m.refusedShare == 0.5)
    #expect(m.falseRefusals == 1)
    #expect(m.medianStrong == 3.5)
    #expect(m.unjudgedAt20 == 2)
  }

  @Test func summaryHasEveryGroupAndOverall() {
    let s = VariantScore(pAt10: 1, pAt20: 1, pAt50: 1, unjudgedAt10: 0, unjudgedAt20: 0, unjudgedAt50: 0,
                         unsureAt20: 0, ndcgAt20: 1, recallAt100: 1, strong: 1, weaker: 0, refused: nil,
                         falseRefusal: false, elapsedMs: 1)
    let e = [QueryEvidence(name: "a", group: "thing", expect: .matches, relevantKnown: 1, judged: 1, albumMembers: nil,
                           variants: ["V0": s]),
             QueryEvidence(name: "b", group: "activity", expect: .matches, relevantKnown: 1, judged: 1,
                           albumMembers: nil, variants: ["V0": s, "V1": s])]
    let summary = FindSummary.make(e, variants: ["V0", "V1"])
    #expect(Set(summary.groups.keys) == ["thing", "activity"])
    #expect(summary.overall["V0"]?.queries == 2)
    #expect(summary.overall["V1"]?.queries == 1)
    #expect(summary.groups["thing"]?["V1"]?.queries == 0)
  }
}

struct PoolingTests {
  @Test func unionInterleavesByRankAndKeepsEachIdOnce() {
    let v0 = ["a", "b", "c", "d"], v1 = ["b", "x", "a", "y"]
    #expect(Pooling.union([v0, v1], k: 3) == ["a", "b", "x", "c"])
    #expect(Pooling.union([v0, v1], k: 10) == ["a", "b", "x", "c", "d", "y"])
    #expect(Pooling.union([], k: 5) == [])
    #expect(Pooling.union([["a"], []], k: 5) == ["a"])
  }

  @Test func unionOnlyLooksAtTheFirstK() {
    #expect(Set(Pooling.union([["a", "b", "c"], ["d", "e", "f"]], k: 1)) == ["a", "d"])
  }

  @Test func allIdsAreDistinctAndSorted() {
    let p1 = PoolFile(slug: "a", query: "a", group: "g", expect: .matches, k: 2, variants: ["V0"], ids: ["z", "b"])
    let p2 = PoolFile(slug: "b", query: "b", group: "g", expect: .matches, k: 2, variants: ["V0"], ids: ["b", "c"])
    #expect(Pooling.allIds([p1, p2]) == ["b", "c", "z"])
  }

  @Test func variantDirectoriesSkipThePoolAndEmptyFolders() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "find-pool-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for d in ["V1", "V0", "pool", "empty"] {
      try FileManager.default.createDirectory(at: root.appending(path: d), withIntermediateDirectories: true)
    }
    for d in ["V1", "V0", "pool"] { try Data("{}".utf8).write(to: root.appending(path: d).appending(path: "q.json")) }
    #expect(try Pooling.variantDirectories(in: root) == ["V0", "V1"])
  }
}

struct SpecTests {
  @Test func textsAreTheBareTextThenEachTemplateOnce() throws {
    let spec = FindSpec(templates: ["a picture of {text}", "a photo of {text}"],
                        queries: [FindQuery(name: "My Dog!", text: "my dog", group: "thing", expect: .matches,
                                            templates: ["{text}"])])
    let q = try #require(try spec.resolved().first)
    #expect(q.slug == "my-dog")
    #expect(q.texts == ["my dog", "a photo of my dog", "a picture of my dog"])
    #expect(q.isPrivate == false)
  }

  @Test func albumQueriesArePrivate() throws {
    let spec = FindSpec(queries: [FindQuery(name: "a", text: "a", group: "album", expect: .matches, albumKey: "al1"),
                                  FindQuery(name: "b", text: "b", group: "album", expect: .matches, albumKeys: ["x"])])
    #expect(try spec.resolved().allSatisfy(\.isPrivate))
  }

  @Test func albumKeyAndAlbumKeysCombine() throws {
    let json = #"{"queries":[{"name":"t","text":"t","group":"album","expect":"matches","albumKey":"a","albumKeys":["b","a","c"]}]}"#
    let spec = try JSONDecoder().decode(FindSpec.self, from: Data(json.utf8))
    #expect(spec.queries[0].allAlbumKeys == ["a", "b", "c"])
    #expect(FindQuery(name: "n", text: "n", group: "g", expect: .matches).allAlbumKeys.isEmpty)
  }

  @Test func namesMustBeUniqueAcrossFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "find-spec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = FindSpec(queries: [FindQuery(name: "Beach", text: "beach", group: "place-trip", expect: .matches)])
    let b = FindSpec(queries: [FindQuery(name: "beach", text: "the beach", group: "place-trip", expect: .matches)])
    try JSONEncoder().encode(a).write(to: dir.appending(path: "a.json"))
    try JSONEncoder().encode(b).write(to: dir.appending(path: "b.json"))
    #expect(try FindSpec.load([dir.appending(path: "a.json")]).count == 1)
    #expect(throws: FindSpec.Invalid.self) { try FindSpec.load([dir.appending(path: "a.json"), dir.appending(path: "b.json")]) }
  }

  @Test func aTemplateWithoutThePlaceholderIsRefused() {
    let spec = FindSpec(templates: ["a photo"], queries: [FindQuery(name: "a", text: "a", group: "g", expect: .matches)])
    #expect(throws: FindSpec.Invalid.self) { try spec.resolved() }
  }

  @Test func theRepoSpecLoads() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../evals/find.json")
    let queries = try FindSpec.load([url.standardizedFileURL])
    #expect(queries.count >= 30)
    #expect(queries.filter { $0.query.expect == .nothing }.count == 12)
    #expect(queries.allSatisfy { !$0.isPrivate && $0.query.albumKey == nil })
  }
}

struct SheetTests {
  @Test func manifestNumbersEachSheetFromOne() {
    let ids = (1...45).map { "id\($0)" }
    let m = SheetManifest.plan(slug: "q", query: "q", ids: ids)
    #expect(m.sheets.map(\.file) == ["sheet-01.png", "sheet-02.png", "sheet-03.png"])
    #expect(m.sheets.map(\.tiles.count) == [20, 20, 5])
    #expect(m.sheets[1].tiles.first == SheetManifest.Tile(n: 1, id: "id21"))
    #expect(m.sheets[1].tiles.last == SheetManifest.Tile(n: 20, id: "id40"))
    #expect(m.sheets[2].tiles.map(\.n) == [1, 2, 3, 4, 5])
    #expect(m.sheets.flatMap(\.tiles).map(\.id) == ids)
    #expect(SheetManifest.plan(slug: "q", query: "q", ids: []).sheets.isEmpty)
  }

  @Test func layoutIsFiveByFourTilesOf256() {
    #expect(SheetLayout.perSheet == 20)
    let first = SheetLayout.frame(0), sixth = SheetLayout.frame(5), last = SheetLayout.frame(19)
    #expect(first.width == 256 && first.height == 256)
    #expect(first.maxY == CGFloat(SheetLayout.height - SheetLayout.gap))  // top left
    #expect(sixth.minX == first.minX && sixth.maxY < first.minY)          // second row
    #expect(last.maxX == CGFloat(SheetLayout.width - SheetLayout.gap) && last.minY == CGFloat(SheetLayout.gap))
  }

  @Test func fittingKeepsTheAspectRatioInsideTheTile() {
    let r = SheetRenderer.fitted(width: 400, height: 200, in: CGRect(x: 0, y: 0, width: 256, height: 256))
    #expect(r.width == 256 && r.height == 128 && r.midY == 128)
  }

  @Test func rendersAPNGWithMissingTiles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "find-sheet-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let url = dir.appending(path: "sheet-01.png")
    try SheetRenderer.render([ctx.makeImage(), nil, ctx.makeImage()], to: url)
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == SheetLayout.width && image.height == SheetLayout.height)
  }

  @Test func thumbIndexReadsTheExportAndSkipsFailures() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "find-thumbs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data([0]).write(to: dir.appending(path: "x.jpg"))
    try Data([0]).write(to: dir.appending(path: ThumbIndex.defaultName("c")))
    let index = """
      {"id":"a","file":"x.jpg","ok":true}
      {"id":"b","file":"y.jpg","ok":false}
      """
    try Data(index.utf8).write(to: dir.appending(path: "index.jsonl"))
    let t = try ThumbIndex(folder: dir)
    #expect(t.url(for: "a")?.lastPathComponent == "x.jpg")
    #expect(t.url(for: "b") == nil)
    #expect(t.url(for: "c") != nil)  // not in the index, found by its default name
    #expect(t.url(for: "d") == nil)
    #expect(ThumbIndex.defaultName("c").count == 20)
    #expect(t.done == ["a", "b"])  // listed, with or without a thumbnail
  }
}

struct JudgmentTests {
  private let manifest = SheetManifest.plan(slug: "dog", query: "my dog", ids: (1...25).map { "id\($0)" })

  @Test func everyTileOfAJudgedSheetGetsAVerdict() throws {
    let v = try JudgmentApplication.verdicts(manifest: manifest, judged: [
      "sheet-01": SheetJudgment(relevant: [1, 3], unsure: [20]),
    ])
    #expect(v.count == 20)
    #expect(v["id1"] == .relevant && v["id3"] == .relevant)
    #expect(v["id20"] == .unsure)
    #expect(v["id2"] == .notRelevant)
    #expect(v["id21"] == nil)  // sheet 2 not judged
  }

  @Test func sheetNamesMayCarryTheExtension() throws {
    let v = try JudgmentApplication.verdicts(manifest: manifest, judged: ["sheet-02.png": SheetJudgment(relevant: [5])])
    #expect(v["id25"] == .relevant && v["id21"] == .notRelevant && v.count == 5)
  }

  @Test func badNumbersAndUnknownSheetsAreRefused() {
    #expect(throws: JudgmentApplication.Failure.self) {
      try JudgmentApplication.verdicts(manifest: manifest, judged: ["sheet-02": SheetJudgment(relevant: [6])])
    }
    #expect(throws: JudgmentApplication.Failure.self) {
      try JudgmentApplication.verdicts(manifest: manifest, judged: ["sheet-09": SheetJudgment()])
    }
    #expect(throws: JudgmentApplication.Failure.self) {
      try JudgmentApplication.verdicts(manifest: manifest, judged: ["sheet-01": SheetJudgment(relevant: [2], unsure: [2])])
    }
  }

  @Test func mergingReplacesOldVerdictsAndAlbumsWin() {
    let old = Labels(relevant: ["a"], notRelevant: ["b", "c"], unsure: ["d"])
    let merged = old.merged(with: ["b": .relevant, "d": .notRelevant, "e": .unsure, "f": .notRelevant],
                            alwaysRelevant: ["f", "g"])
    #expect(merged.relevant == ["a", "b", "f", "g"])
    #expect(merged.notRelevant == ["c", "d"])
    #expect(merged.unsure == ["e"])
    #expect(merged.judged.count == 7)
  }

  @Test func judgmentsDecodeTheJudgeFormat() throws {
    let json = #"{"my-dog": {"sheet-01": {"relevant": [1, 2]}, "sheet-02": {"relevant": [], "unsure": [4]}}}"#
    let j = try JSONDecoder().decode(Judgments.self, from: Data(json.utf8))
    #expect(j["my-dog"]?["sheet-01"] == SheetJudgment(relevant: [1, 2]))
    #expect(j["my-dog"]?["sheet-02"]?.unsure == [4])
  }

  @Test func labelsWithoutUnsureDecode() throws {
    let l = try JSONDecoder().decode(Labels.self, from: Data(#"{"relevant":["a"],"notRelevant":["b"]}"#.utf8))
    #expect(l == Labels(relevant: ["a"], notRelevant: ["b"]))
    #expect(l.verdict("a") == .relevant && l.verdict("z") == nil)
  }

  @Test func albumKeysAreUnitedAndMembersWithoutAVectorSetApart() throws {
    let members: [String: Set<String>] = ["k1": ["1", "2"], "k2": ["2", "3", "new"]]
    let split = try Albums.split(keys: ["k1", "k2"], members: members, indexed: ["1", "2", "3", "x"])
    #expect(split.withVector == ["1", "2", "3"])
    #expect(split.withoutVector == 1)
    #expect(try Albums.split(keys: ["k2"], members: members, indexed: nil).withVector.count == 3)
    #expect(throws: FindSpec.Invalid.self) { try Albums.split(keys: ["nope"], members: members, indexed: nil) }
  }

  @Test func labelsCanBeRestrictedToIndexedIds() {
    let l = Labels(relevant: ["a", "new"], notRelevant: ["b"], unsure: ["gone"])
    #expect(l.restricted(to: ["a", "b"]) == Labels(relevant: ["a"], notRelevant: ["b"]))
    #expect(l.restricted(to: nil) == l)
  }

  @Test func albumMembersComeFromTheExport() {
    let assets = [ExportAsset(id: "1", albums: ["k1", "k2"]), ExportAsset(id: "2", albums: ["k1"]), ExportAsset(id: "3")]
    #expect(Albums.members(assets) == ["k1": ["1", "2"], "k2": ["1"]])
  }
}
