import Testing
@testable import Squish
import Store

private let MB: Int64 = 1_000_000

struct SquishPlannerTests {
  @Test func targetBitrateIsResolutionTimesFpsWithFloorAndCap() {
    let hd30 = SquishCandidates.hevcTargetBitrate(pixelW: 1920, pixelH: 1080, fps: 30)
    let hd60 = SquishCandidates.hevcTargetBitrate(pixelW: 1920, pixelH: 1080, fps: 60)
    #expect(abs(hd60 / hd30 - 2) < 1e-9)
    #expect(SquishCandidates.hevcTargetBitrate(pixelW: 3840, pixelH: 2160, fps: 30) > hd30)
    #expect(SquishCandidates.hevcTargetBitrate(pixelW: 320, pixelH: 240, fps: 24) == SquishCandidates.minTargetBitrate)
    #expect(SquishCandidates.hevcTargetBitrate(pixelW: 7680, pixelH: 4320, fps: 60) == SquishCandidates.maxTargetBitrate)
  }

  @Test func plannedBitrateNeverExceedsTheSource() {
    #expect(SquishCandidates.plannedOutputBitrate(pixelW: 1920, pixelH: 1080, fps: 30, sourceBitrate: 1_000_000) == 1_000_000)
    let t = SquishCandidates.hevcTargetBitrate(pixelW: 1920, pixelH: 1080, fps: 30)
    #expect(SquishCandidates.plannedOutputBitrate(pixelW: 1920, pixelH: 1080, fps: 30, sourceBitrate: 90_000_000) == t)
  }

  @Test func downscaleFitsTheBoxAndKeepsAspect() {
    #expect(Downscale.forSource(w: 3840, h: 2160, keep4K: false) == Downscale(fromW: 3840, fromH: 2160, toW: 1920, toH: 1080))
    #expect(Downscale.forSource(w: 2160, h: 3840, keep4K: false) == Downscale(fromW: 2160, fromH: 3840, toW: 1080, toH: 1920))
    #expect(Downscale.forSource(w: 1920, h: 1080, keep4K: false) == nil)
    #expect(Downscale.forSource(w: 1280, h: 720, keep4K: false) == nil)
    #expect(Downscale.forSource(w: 3840, h: 2160, keep4K: true) == nil)
  }

  @Test func fourKVideoIsPlannedWithItsDownscale() throws {
    let r = AssetRecordFixtures.video(bytes: 100 * MB, seconds: 10, w: 3840, h: 2160)
    let item = try #require(SquishPlanner.plan(records: [r], keep4K: false).first)
    #expect(item.downscale == Downscale(fromW: 3840, fromH: 2160, toW: 1920, toH: 1080))
    #expect(item.estimatedOutputBytes < item.estimatedBytes)
    #expect(item.estimatedSavings == item.estimatedBytes - item.estimatedOutputBytes)
    let kept = try #require(SquishPlanner.plan(records: [r], keep4K: true).first)
    #expect(kept.downscale == nil)
    #expect(kept.estimatedOutputBytes > item.estimatedOutputBytes)
  }

  @Test func itemsBelowThirtyPercentSavingsAreDropped() {
    #expect(SquishPlanner.minimumSavingsFraction == 0.30)
    // 60 MB over 600 s is about 0.8 Mbps: already below the HEVC target, nothing to gain.
    #expect(SquishPlanner.plan(records: [AssetRecordFixtures.video(bytes: 60 * MB, seconds: 600)], keep4K: false).isEmpty)
    // 50 MB over 10 s is 40 Mbps at 1080p: huge saving.
    #expect(SquishPlanner.plan(records: [AssetRecordFixtures.video(bytes: 50 * MB + 1, seconds: 10)], keep4K: false).count == 1)
  }

  @Test func estimatedOutputNeverExceedsInput() {
    let records = [
      AssetRecordFixtures.video(bytes: 80 * MB, seconds: 300), AssetRecordFixtures.video(bytes: 400 * MB, seconds: 20),
      AssetRecordFixtures.photo(bytes: 5 * MB), AssetRecordFixtures.photo(bytes: 5 * MB, uti: "public.png"),
    ]
    for item in SquishPlanner.plan(records: records, keep4K: false) { #expect(item.estimatedOutputBytes <= item.estimatedBytes) }
  }

  @Test func photosUseTheirFormatRatios() throws {
    let jpeg = try #require(SquishPlanner.plan(records: [AssetRecordFixtures.photo(bytes: 5 * MB)], keep4K: false).first)
    let png = try #require(SquishPlanner.plan(records: [AssetRecordFixtures.photo(bytes: 5 * MB, uti: "public.png")], keep4K: false).first)
    #expect(jpeg.kind == .photo && png.kind == .photo)
    #expect(png.estimatedSavings > jpeg.estimatedSavings)
    #expect(jpeg.downscale == nil)
  }

  @Test func nonCandidatesAreSkipped() {
    var live = AssetRecordFixtures.photo(bytes: 9 * MB)
    live.subtypes = SquishCandidates.photoLive
    #expect(SquishPlanner.plan(records: [live], keep4K: false).isEmpty)
  }
}
