import Foundation
import Testing
@testable import Dedupe
import Store

/// Feature prints are opaque here: the payload is the asset id, and the injected distance looks
/// the pair up in a table (default far apart).
private struct Distances {
  var table: [Set<String>: Float] = [:]
  func callAsFunction(_ a: Data, _ b: Data) -> Float {
    table[[String(decoding: a, as: UTF8.self), String(decoding: b, as: UTF8.self)]] ?? 1.0
  }
}

private func rec(_ id: String, at created: Double?, bytes: Int64 = 1_000, phash: UInt64? = nil,
                 fp: Bool = true, mediaType: Int = 1, deleted: Bool = false, burst: String? = nil) -> AssetRecord {
  AssetRecord(id: id, mediaType: mediaType, subtypes: 0, created: created, burstId: burst, estBytes: bytes,
              phash: phash, featurePrint: fp ? Data(id.utf8) : nil, deleted: deleted)
}

/// A hash that is neither blank-looking nor saturated, so the global exact pass accepts it.
private let usableHash: UInt64 = 0xDEAD_BEEF_CAFE_F00D

struct HammingTests {
  @Test func countsDifferingBits() {
    #expect(hamming(0, 0) == 0)
    #expect(hamming(0b1011, 0b0001) == 2)
    #expect(hamming(.max, 0) == 64)
    #expect(hamming(.max, .max) == 0)
  }
}

struct DuplicateGrouperTests {
  @Test func threeShotsThirtySecondsApartFormOneGroup() {
    let records = [rec("a", at: 1000), rec("b", at: 1030), rec("c", at: 1060)]
    var d = Distances()
    d.table = [["a", "b"]: 0.2, ["b", "c"]: 0.2, ["a", "c"]: 0.2]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["a", "b", "c"]])
  }

  @Test func sameShotsTenMinutesApartMakeNoGroup() {
    let records = [rec("a", at: 1000), rec("b", at: 1600), rec("c", at: 2200)]
    var d = Distances()
    d.table = [["a", "b"]: 0.2, ["b", "c"]: 0.2, ["a", "c"]: 0.2]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction).isEmpty)
  }

  @Test func exactPhashLinksAcrossTime() {
    let records = [rec("a", at: 1000, phash: 0xDEAD_BEEF), rec("b", at: 90_000, phash: 0xDEAD_BEEF),
                   rec("c", at: 50_000, phash: 0xDEAD_BEEE)]
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 1 } == [["a", "b"]])
  }

  @Test func nearPhashLinksOnlyInsideWindow() {
    let near = rec("a", at: 1000, phash: 0b1111), nearToo = rec("b", at: 1050, phash: 0b0000)  // hamming 4
    let tooFar = rec("c", at: 1100, phash: 0b1111_1000)  // hamming 5 from b, 7 from a
    #expect(DuplicateGrouper.groups(records: [near, nearToo, tooFar]) { _, _ in 1 } == [["a", "b"]])
    let late = rec("d", at: 9000, phash: 0b0001)  // hamming 1 from b but outside the window
    #expect(DuplicateGrouper.groups(records: [near, nearToo, late]) { _, _ in 1 } == [["a", "b"]])
  }

  @Test func thresholdIsExclusive() {
    let records = [rec("a", at: 0), rec("b", at: 10)]
    var d = Distances()
    d.table = [["a", "b"]: DuplicateGrouper.fpThreshold]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction).isEmpty)
    d.table = [["a", "b"]: DuplicateGrouper.fpThreshold.nextDown]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction).count == 1)
  }

  /// The span is measured from the group's first shot, and its edge is inclusive.
  @Test func windowEdgeIsInclusive() {
    var d = Distances()
    d.table = [["a", "b"]: 0.1, ["a", "c"]: 0.1]
    let records = [rec("a", at: 0), rec("b", at: 60), rec("c", at: 60.5)]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["a", "b"]])
  }

  // MARK: star linkage: every member is close to the group's first shot

  /// a~b and b~c, but a and c look nothing alike: c is not in a's group, even though all three are seconds apart.
  @Test func aChainOfLookAlikesIsNotOneGroup() {
    var d = Distances()
    d.table = [["a", "b"]: 0.1, ["b", "c"]: 0.1, ["a", "c"]: 0.9]
    let records = [rec("c", at: 20), rec("a", at: 0), rec("b", at: 10)]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["a", "b"]])
  }

  /// A long run of shots each like the previous one (a slow pan, a scrolled chat) splits at every shot that has drifted
  /// away from the run's first: no group holds two shots that look nothing alike.
  @Test func aDriftingRunSplitsWhereItLeavesTheFirstShot() {
    var d = Distances()
    // s0...s5, 5 s apart: each is close to the two before it, far from anything older.
    for i in 0..<5 { d.table[["s\(i)", "s\(i + 1)"]] = 0.1 }
    for i in 0..<4 { d.table[["s\(i)", "s\(i + 2)"]] = 0.2 }
    let records = (0..<6).map { rec("s\($0)", at: Double($0) * 5) }
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["s0", "s1", "s2"], ["s3", "s4", "s5"]])
  }

  /// The span runs from the first shot, not from the latest member: a shot 50 s after the second but 80 s after the
  /// first starts its own group.
  @Test func spanCountsFromTheFirstShot() {
    let records = [rec("a", at: 0), rec("b", at: 30), rec("c", at: 80), rec("d", at: 85)]
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 0.1 } == [["a", "b"], ["c", "d"]])
  }

  /// Near hashes link to the first shot only: a is 4 bits from b and 8 from c.
  @Test func nearHashesDoNotChainEither() {
    let records = [rec("a", at: 0, phash: 0b0000, fp: false), rec("b", at: 5, phash: 0b1111, fp: false),
                   rec("c", at: 10, phash: 0b1111_1111, fp: false)]
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 1 } == [["a", "b"]])
  }

  /// A burst of 40 shots in one second, all alike, is one group: the neighbour cap is above a real burst.
  @Test func aBurstOfAlikeShotsIsOneGroup() {
    let records = (0..<40).map { rec(String(format: "s%02d", $0), at: 100 + Double($0) * 0.01) }
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 0.1 }.map(\.count) == [40])
  }

  /// Exact copies come out first as their own group (Duplicates); the rest of the moment groups around its first shot.
  @Test func exactCopiesInsideAMomentAreTheirOwnGroup() {
    var d = Distances()
    d.table = [["a", "b"]: 0.1, ["a", "c"]: 0.2, ["b", "c"]: 0.2, ["c", "e"]: 0.1, ["a", "e"]: 0.1, ["b", "e"]: 0.1]
    let records = [rec("a", at: 0), rec("b", at: 3, phash: usableHash), rec("c", at: 6), rec("e", at: 9, phash: usableHash)]
    let groups = DuplicateGrouper.groups(records: records, distance: d.callAsFunction)
    #expect(groups == [["a", "c"], ["b", "e"]])
  }

  @Test func groupsOrderedByTotalBytesThenSizeThenId() {
    var d = Distances()
    d.table = [["a1", "a2"]: 0.1, ["b1", "b2"]: 0.1, ["c1", "c2"]: 0.1, ["d1", "d2"]: 0.1]
    let records = [
      rec("a1", at: 0, bytes: 100), rec("a2", at: 1, bytes: 100),       // 200
      rec("b1", at: 1000, bytes: 500), rec("b2", at: 1001, bytes: 500), // 1000
      rec("c1", at: 2000, bytes: 100), rec("c2", at: 2001, bytes: 100), // 200, ties with a
      rec("d1", at: 3000, bytes: 700), rec("d2", at: 3001, bytes: 700), // 1400
    ]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction)
            == [["d1", "d2"], ["b1", "b2"], ["a1", "a2"], ["c1", "c2"]])
  }

  @Test func outputIsIndependentOfInputOrder() {
    var d = Distances()
    d.table = [["a", "b"]: 0.1, ["b", "c"]: 0.1, ["x", "y"]: 0.1]
    let records = [rec("a", at: 0), rec("b", at: 10), rec("c", at: 20), rec("x", at: 500), rec("y", at: 505)]
    let expected = DuplicateGrouper.groups(records: records, distance: d.callAsFunction)
    for _ in 0..<10 {
      #expect(DuplicateGrouper.groups(records: records.shuffled(), distance: d.callAsFunction) == expected)
    }
  }

  @Test func simultaneousShotsTieBreakOnId() {
    var d = Distances()
    d.table = [["a", "b"]: 0.1]
    let records = [rec("b", at: 50), rec("a", at: 50)]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["a", "b"]])
  }

  @Test func ignoresDeletedMissingPrintsAndMixedMediaTypes() {
    var d = Distances()
    d.table = [["a", "gone"]: 0.1, ["a", "nofp"]: 0.1, ["a", "video"]: 0.1]
    let records = [rec("a", at: 0), rec("gone", at: 5, deleted: true), rec("nofp", at: 6, fp: false),
                   rec("video", at: 7, mediaType: 2)]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction).isEmpty)
  }

  @Test func undatedRecordsOnlyLinkByExactPhash() {
    var d = Distances()
    d.table = [["a", "b"]: 0.1]
    let records = [rec("a", at: nil), rec("b", at: nil), rec("p", at: nil, phash: usableHash), rec("q", at: 3, phash: usableHash)]
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["q", "p"]])
  }

  @Test func emptyAndSingleInputs() {
    #expect(DuplicateGrouper.groups(records: []) { _, _ in 0 }.isEmpty)
    #expect(DuplicateGrouper.groups(records: [rec("a", at: 0)]) { _, _ in 0 }.isEmpty)
  }

  @Test func constantsArePublic() {
    // Chosen on the founder's library: docs/investigations/2026-10-29-similar-blurry.md.
    #expect(DuplicateGrouper.window == 60)
    #expect(DuplicateGrouper.fpThreshold == 0.30)
    #expect(DuplicateGrouper.nearPhashDistance == 4)
    #expect(DuplicateGrouper.maxNeighbors == 64)
  }

  // MARK: burst cost

  @Test func sameBurstIdLinksWithoutAnyComparison() {
    let records = [rec("a", at: 0, fp: false, burst: "B1"), rec("b", at: 5_000, fp: false, burst: "B1"),
                   rec("c", at: 10, fp: false, burst: "B2"), rec("d", at: 9_000, fp: false, burst: "B3")]
    var calls = 0
    let groups = DuplicateGrouper.groups(records: records) { _, _ in calls += 1; return 0 }
    #expect(groups == [["a", "b"]])
    #expect(calls == 0)
  }

  @Test func twoHundredDistinctShotsWithOneTimestampStayBounded() {
    var state: UInt64 = 42
    func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 11 }
    let records = (0..<200).map { i in
      AssetRecord(id: "s\(i)", mediaType: 1, subtypes: 0, created: 5_000, phash: next() | (1 << 63),
                  featurePrint: Data("fp\(i)".utf8))
    }
    var calls = 0, prepares = 0
    let groups = DuplicateGrouper.groups(records: records, prepare: { d -> Data? in prepares += 1; return d },
                                         distance: { _, _ in calls += 1; return 1.0 })
    #expect(groups.isEmpty)
    #expect(calls <= records.count * DuplicateGrouper.maxNeighbors)
    #expect(calls > 0)
    #expect(prepares <= records.count)
  }

  @Test func prepareRunsLazilyAndAtMostOncePerRecord() {
    let records = [rec("a", at: 0), rec("b", at: 10), rec("c", at: 20), rec("n", at: 5_000, fp: false)]
    var prepared: [String] = []
    _ = DuplicateGrouper.groups(records: records, prepare: { d -> String? in
      prepared.append(String(decoding: d, as: UTF8.self)); return prepared.last
    }, distance: { _, _ in 1.0 })
    #expect(prepared.sorted() == ["a", "b", "c"])  // "n" has no print and no neighbors; nothing decoded twice
    var none = 0
    _ = DuplicateGrouper.groups(records: [rec("x", at: 0, fp: false), rec("y", at: 1, fp: false)],
                                prepare: { _ -> Int? in none += 1; return 1 }, distance: { _, _ in 0 })
    #expect(none == 0)
  }

  @Test func printsThatFailToDecodeNeverLink() {
    let records = [rec("a", at: 0), rec("b", at: 10)]
    var distanceCalls = 0
    let groups = DuplicateGrouper.groups(records: records, prepare: { _ -> Int? in nil },
                                         distance: { _, _ in distanceCalls += 1; return 0 })
    #expect(groups.isEmpty)
    #expect(distanceCalls == 0)
  }

  /// 200 alike shots in one second: each first shot examines at most `maxNeighbors` unclaimed successors, so groups
  /// hold at most 1 + maxNeighbors and the comparisons stay bounded.
  @Test func neighborCapBoundsGroupsAndComparisons() throws {
    let records = (0..<200).map { rec(String(format: "s%03d", $0), at: 100 + Double($0) * 0.001) }
    var calls = 0
    let groups = DuplicateGrouper.groups(records: records) { _, _ in calls += 1; return 0.1 }
    let cap = DuplicateGrouper.maxNeighbors
    try #require(groups.map(\.count) == [cap + 1, cap + 1, cap + 1, 200 - 3 * (cap + 1)])
    #expect(groups[0].first == "s000" && groups[1].first == "s065")
    #expect(calls <= records.count * cap)
  }

  /// 2,000 shots saved with one timestamp, alike only in pairs: 1,000 pairs, and the comparisons stay bounded.
  @Test func savedBatchAlikeInPairsMakesPairs() {
    var d = Distances()
    for i in stride(from: 0, to: 2_000, by: 2) { d.table[[String(format: "s%04d", i), String(format: "s%04d", i + 1)]] = 0.1 }
    let records = (0..<2_000).map { rec(String(format: "s%04d", $0), at: 7) }
    var calls = 0
    let groups = DuplicateGrouper.groups(records: records) { a, b in calls += 1; return d(a, b) }
    #expect(groups.count == 1_000 && groups.allSatisfy { $0.count == 2 })
    #expect(calls <= records.count * DuplicateGrouper.maxNeighbors)
  }

  // MARK: large exact-hash buckets use the same star rule

  @Test func largeBucketLinksToItsFirstShotOnly() {
    var d = Distances()
    d.table = [["x0", "x1"]: 0.1, ["x1", "x2"]: 0.1, ["x0", "x2"]: 0.9]
    let records = (0..<10).map { rec("x\($0)", at: Double($0) * 500_000, phash: usableHash) }
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["x0", "x1"]])
  }

  // MARK: exact-hash mega-groups

  @Test func thousandBlackFramesAcrossAYearFormNoGroup() {
    let records = (0..<1_000).map { rec("black\($0)", at: Double($0) * 31_536, phash: 0, fp: false) }
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 1 }.isEmpty)
  }

  @Test(arguments: [UInt64.max, 0, 0b1111, 0xFFFF_FFFF_FFFF_FFF0, 0xFFFF_FFFF_FFFF_FFFE])
  func degenerateHashesNeverLinkGlobally(hash: UInt64) {
    let records = [rec("a", at: 0, phash: hash, fp: false), rec("b", at: 1_000_000, phash: hash, fp: false)]
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 1 }.isEmpty)
  }

  @Test func hashesJustInsideTheUsableRangeStillLink() {
    func pair(_ h: UInt64) -> Int {
      DuplicateGrouper.groups(records: [rec("a", at: 0, phash: h, fp: false), rec("b", at: 1_000_000, phash: h, fp: false)]) { _, _ in 1 }.count
    }
    #expect(pair(0b11111) == 1)                       // popcount 5
    #expect(pair(.max & ~0b11111) == 1)               // popcount 59
    #expect(pair(.max & ~0b1111) == 0)                // popcount 60
  }

  @Test func largeBucketOfDistinctPrintsDoesNotMerge() {
    // The same app screen screenshotted over months: identical hash, clearly different prints.
    let records = (0..<20).map { rec("shot\($0)", at: Double($0) * 500_000, phash: usableHash) }
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 1.0 }.isEmpty)
  }

  @Test func largeBucketLinksOnlyPairsWithCloseUsablePrints() {
    var d = Distances()
    d.table = [["shot3", "shot4"]: 0.1]
    var records = (0..<12).map { rec("shot\($0)", at: Double($0) * 500_000, phash: usableHash) }
    records.append(rec("noprint", at: 9_000_000, phash: usableHash, fp: false))
    #expect(DuplicateGrouper.groups(records: records, distance: d.callAsFunction) == [["shot3", "shot4"]])
  }

  @Test func bucketOfEightStillLinksWithoutPrints() {
    let records = (0..<8).map { rec("x\($0)", at: Double($0) * 500_000, phash: usableHash, fp: false) }
    #expect(DuplicateGrouper.groups(records: records) { _, _ in 1 }.map(\.count) == [8])
    let nine = (0..<9).map { rec("x\($0)", at: Double($0) * 500_000, phash: usableHash, fp: false) }
    #expect(DuplicateGrouper.groups(records: nine) { _, _ in 1 }.isEmpty)
  }

  /// 50k assets ~2 s apart (about 60 neighbors per window). Comparisons are capped per record, so the
  /// call count is bounded; wall time stays well under 2 s in release (debug gets a sanity bound).
  @Test func fiftyThousandRecordsStayFastAndBounded() {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 11 }
    var records: [AssetRecord] = []
    records.reserveCapacity(50_000)
    for i in 0..<50_000 {
      // Every 500th asset repeats an earlier hash: 100 planted exact duplicates, far apart in time.
      let hash = (i % 500 == 499) ? records[i - 250].phash : next() | 0x8000_0000_0000_0000
      records.append(AssetRecord(id: "id\(i)", mediaType: 1, subtypes: 0, created: Double(i) * 2,
                                 estBytes: Int64(next() % 5_000_000), phash: hash,
                                 featurePrint: Data(repeating: UInt8(i & 0xFF), count: 8)))
    }
    var calls = 0, prepares = 0
    let start = ContinuousClock.now
    let groups = DuplicateGrouper.groups(records: records, prepare: { d -> Data? in prepares += 1; return d },
                                         distance: { _, _ in calls += 1; return 1.0 })
    let elapsed = ContinuousClock.now - start
    print("DEDUPE-PERF 50k records: \(elapsed), distance calls: \(calls), prepares: \(prepares), groups: \(groups.count)")
    #expect(groups.count >= 100)
    #expect(calls <= records.count * DuplicateGrouper.maxNeighbors)
    #expect(prepares <= records.count)
    #if DEBUG
    #expect(elapsed < .seconds(60))
    #else
    #expect(elapsed < .seconds(2))
    #endif
  }
}

struct DuplicateGrouperExclusionTests {
  @Test func excludedIdsNeverJoinAGroup() {
    // "orig" and "copy" are the same shot (a squished copy and its original); "other" is a real duplicate of "orig".
    let records = [rec("orig", at: 100, phash: usableHash), rec("copy", at: 100, phash: usableHash), rec("other", at: 101, phash: usableHash)]
    #expect(DuplicateGrouper.groups(records: records, distance: Distances().callAsFunction) == [["copy", "orig", "other"]])
    #expect(DuplicateGrouper.groups(records: records, excluding: ["copy"], distance: Distances().callAsFunction) == [["orig", "other"]])
    #expect(DuplicateGrouper.groups(records: records, excluding: ["copy", "other"], distance: Distances().callAsFunction).isEmpty)
  }
}
