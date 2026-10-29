import Dedupe
import Foundation
import Overview
import Signals
import Store
import Testing

/// Evidence for the Similar shots rule (docs/investigations/2026-10-29-similar-blurry.md). See `Evidence` for the
/// environment variables. Writes `similar-distances.json` (print distances, the old rule's biggest groups),
/// `similar-rules-<k>.json` (Home's numbers per candidate rule) and `similar-current-code-<phase>.json` (this
/// checkout's `DuplicateGrouper`, with `ROLL_EVIDENCE_PHASE`, default `current`).
@Suite(.enabled(if: Evidence.enabled, "evidence tool: needs ROLL_EVIDENCE_DB and ROLL_EVIDENCE_OUT"))
struct SimilarEvidenceTests {
  static let edges: [Float] = [0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 0.6, 0.8, 1.0]

  @Test func similarRules() async throws {
    try await Evidence.withCopy { repo in
      let live = try await repo.liveAssets()
      let copies = try await repo.journaledCopyIDs()
      let lab = GroupingLab(live.filter { $0.groupable && !copies.contains($0.id) })
      var out: [String: Any] = ["liveAssets": live.count, "groupableRows": lab.count,
                                "images": live.filter { $0.mediaType == 1 }.count]

      // 1. Print distances of the pairs the old window pass compared, and of pairs that are surely one scene.
      let pairs = lab.windowPairs()
      var all: [Float] = [], linked: [Float] = [], nearHash: [Float] = [], within2s: [Float] = [],
          over30s: [Float] = [], sameInstant: [Float] = [], linkedByHash = 0
      for (i, j) in pairs {
        guard let d = lab.distance(i, j) else { continue }
        all.append(d)
        if lab.nearHash(i, j) { linkedByHash += 1; nearHash.append(d) } else if d < 0.35 { linked.append(d) }
        let camera = lab.records[i].subtypes & 4 == 0 && lab.records[j].subtypes & 4 == 0 && lab.records[i].mediaType == 1
        let gap = lab.created[j] - lab.created[i]
        if gap == 0 { sameInstant.append(d) } else if camera && gap <= 2 { within2s.append(d) }
        if camera && gap >= 30 { over30s.append(d) }
      }
      func dist(_ v: [Float]) -> [String: Any] { ["distance": Evidence.spread(v), "histogram": Evidence.histogram(v, edges: Self.edges)] }
      out["windowPairs"] = ["compared": all.count, "linkedByPrint(<0.35)": linked.count, "linkedByHash": linkedByHash,
                            "all": dist(all), "nearHashPairs": dist(nearHash),
                            "cameraPhotos0to2sApart": dist(within2s), "cameraPhotos30to120sApart": dist(over30s),
                            "sameTimestamp": dist(sameInstant)]

      // 2. The old rule's biggest groups: linked pairs are all under 0.35, the rest of the group isn't.
      let old = lab.unionFind(threshold: 0.35)
      var big: [[String: Any]] = []
      for g in old.sorted(by: { $0.count > $1.count }).prefix(5) {
        let members = Set(g)
        var groupLinks: [Float] = []
        for (i, j) in pairs where members.contains(i) && members.contains(j) {
          if let d = lab.distance(i, j), d < 0.35 || lab.nearHash(i, j) { groupLinks.append(d) }
        }
        var allPairs: [Float] = []
        for x in 0..<g.count { for y in (x + 1)..<g.count { if let d = lab.distance(g[x], g[y]) { allPairs.append(d) } } }
        let far = allPairs.filter { $0 >= 0.35 }.count
        big.append(["members": g.count, "linkedPairDistance": Evidence.spread(groupLinks),
                    "allPairDistance": Evidence.spread(allPairs),
                    "pctPairsNotSimilar(>=0.35)": Evidence.round3(Double(far) / Double(max(allPairs.count, 1)) * 100),
                    "sanity": lab.sanity([g])])
      }
      out["oldLargestGroups"] = big

      // 3. Group sizes per rule: union-find at three thresholds, then star linkage around each group's first shot.
      var rules: [[String: Any]] = []
      for t: Float in [0.35, 0.30, 0.25] {
        var row = lab.describe(t == 0.35 ? old : lab.unionFind(threshold: t), live: live)
        row["rule"] = "unionFind t=\(t) window=120s"
        rules.append(row)
      }
      var anchorRules: [GroupingLab.AnchorRule] = []
      for t: Float in [0.35, 0.30, 0.25, 0.20] {
        for span in [60.0, 120.0] { anchorRules.append(.init(threshold: t, span: span, cap: 64)) }
      }
      anchorRules += [.init(threshold: 0.30, span: 60, cap: 24), .init(threshold: 0.30, span: 30, cap: 64)]
      for t: Float in [0.35, 0.30, 0.25] { anchorRules.append(.init(threshold: t, span: 60, cap: 64, exactFirst: false)) }
      for rule in anchorRules {
        let result = lab.anchor(rule)
        var row = lab.describe(result.groups, live: live)
        row["rule"] = rule.description; row["capHits"] = result.capHits; row["comparisons"] = result.comparisons
        row["orphanedExactCopies"] = result.orphans
        rules.append(row)
      }
      // Four rules per file: the repo's pre-commit hook refuses files over ~20 KB.
      for (k, start) in stride(from: 0, to: rules.count, by: 4).enumerated() {
        try Evidence.write("similar-rules-\(k + 1).json", ["rules": Array(rules[start..<min(start + 4, rules.count)])])
      }

      // 4. What the code in this checkout does, and whether the lab reproduces it.
      let start = ContinuousClock.now
      let shipped = DuplicateGrouper.groups(records: lab.records, excluding: copies, prepare: FeaturePrints.decode,
                                            distance: { $0.distance(to: $1) })
      let elapsed = (ContinuousClock.now - start).components
      var current = Evidence.groupStats(shipped, live: live)
      current["macDebugSeconds"] = Evidence.round3(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
      let canon = { (gs: [[String]]) in Set(gs.map { $0.sorted() }) }
      current["equalsOldUnionFind"] = canon(shipped) == canon(lab.ids(old))
      let constants = GroupingLab.AnchorRule(threshold: DuplicateGrouper.fpThreshold, span: DuplicateGrouper.window,
                                             cap: DuplicateGrouper.maxNeighbors)
      current["equalsAnchorWithShippedConstants"] = canon(shipped) == canon(lab.ids(lab.anchor(constants).groups))
      current["constants"] = constants.description
      // Home's whole picture with these groups, as `CleanupScanner.scan(groups:)` builds it on the phone.
      let home = try await CleanupScanner(repositories: repo).scan(groups: shipped)
      current["home"] = ["freeableGB": Evidence.gb(home.freeableBytes), "freeableOnDeviceGB": Evidence.gb(home.freeableOnDevice),
                         "blurry": home[.blurry].count, "blurryGB": Evidence.gb(home[.blurry].bytes),
                         "similarExtras": home[.similarShots].count, "duplicateExtras": home[.duplicates].count]
      try Evidence.write("similar-current-code-\(Evidence.env["ROLL_EVIDENCE_PHASE"] ?? "current").json", current)
      try Evidence.write("similar-distances.json", out)
    }
  }
}
