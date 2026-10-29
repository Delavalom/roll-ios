import Foundation
import Overview
import Ranking
import Store
import Testing

/// Evidence for the Blurry pile (docs/investigations/2026-10-29-similar-blurry.md): what each filter picks on a real
/// library, split by media type, through both the Swift filter and the SQL pool. Writes `blurry-<phase>.json`, with
/// `ROLL_EVIDENCE_PHASE` (default `current`) naming the code it ran against.
@Suite(.enabled(if: Evidence.enabled, "evidence tool: needs ROLL_EVIDENCE_DB and ROLL_EVIDENCE_OUT"))
struct BlurryEvidenceTests {
  @Test func blurryCounts() async throws {
    try await Evidence.withCopy { repo in
      let live = try await repo.liveAssets()
      func split(_ picked: [AssetRecord]) -> [String: Any] {
        var out: [String: Any] = ["count": picked.count, "GB": Evidence.gb(picked.reduce(0) { $0 + $1.estBytes })]
        for (name, media) in [("photos", Preset.imageMediaType), ("videos", Preset.videoMediaType)] {
          let part = picked.filter { $0.mediaType == media }
          out[name] = ["count": part.count, "GB": Evidence.gb(part.reduce(0) { $0 + $1.estBytes })]
        }
        return out
      }
      let blurry = { (r: AssetRecord) in r.blur.map { $0 < AssetRecord.blurryBelow } ?? false }
      let lowScore = { (r: AssetRecord) in r.aesthetic.map { $0 < -0.3 } ?? false }
      let old = CandidateFilter(blurBelow: AssetRecord.blurryBelow, aestheticBelow: -0.3)
      var out: [String: Any] = [
        "liveAssets": live.count,
        "blurBelow25_anySize": split(live.filter(blurry)),
        "blurBelow25_qualityTrusted": split(live.filter { blurry($0) && $0.qualityTrusted }),
        "blurBelow25_notQualityTrusted": split(live.filter { blurry($0) && !$0.qualityTrusted }),
        "aestheticBelow-0.3_qualityTrusted": split(live.filter { lowScore($0) && $0.qualityTrusted }),
        "oldFilter(blur<25 OR aesthetic<-0.3)": split(live.filter { old.matches(RankingAsset($0)) }),
        "presetNow": split(live.filter(Preset.blurry.candidateFilter)),
        "presetNowFilter": Preset.blurry.filter.description,
      ]
      // previewSide of the blurry photos: how many sit near the quality-trusted edge (256 px).
      let sides = live.filter { blurry($0) && $0.mediaType == Preset.imageMediaType }.map { $0.previewSide ?? 0 }
      out["blurryPhotoPreviewSide"] = ["n": sides.count, "below256": sides.filter { $0 < 256 }.count,
                                       "256to287": sides.filter { (256..<288).contains($0) }.count,
                                       "288OrMore": sides.filter { $0 >= 288 }.count,
                                       "min": sides.min() ?? 0, "max": sides.max() ?? 0]
      // The SQL pool for the same filter (a swipefile id with no decisions, so nothing is excluded).
      let pool = try await repo.rankingCandidates(swipefileId: "__evidence__", embeddedOnly: false, filter: Preset.blurry.filter)
      out["presetNowSQLPool"] = ["count": pool.count, "GB": Evidence.gb(pool.reduce(0) { $0 + $1.estBytes }),
                                 "videos": pool.filter { $0.mediaType == Preset.videoMediaType }.count,
                                 "sameIdsAsSwift": Set(pool.map(\.id)) == Set(live.filter(Preset.blurry.candidateFilter).map(\.id))]
      // Home's Blurry card, as `CleanupScanner.scan(groups:)` builds it (no groups needed for this category).
      let home = try await CleanupScanner(repositories: repo).scan(groups: [])[.blurry]
      out["homeCard"] = ["count": home.count, "GB": Evidence.gb(home.bytes), "onDeviceGB": Evidence.gb(home.onDeviceBytes)]
      try Evidence.write("blurry-\(Evidence.env["ROLL_EVIDENCE_PHASE"] ?? "current").json", out)
    }
  }
}
