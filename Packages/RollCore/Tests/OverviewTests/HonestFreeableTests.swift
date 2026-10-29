import Foundation
import Overview
import Signals
import Ranking
import Store
import Testing

/// "You can free about X" counts only what's on this iPhone (as the Indexer saw it, network off). Originals in iCloud
/// are reported separately, and nothing shown can exceed the space the device has in use.
struct HonestFreeableTests {
  static func cloud(_ record: AssetRecord) -> AssetRecord {
    var r = record
    r.originalLocal = false
    return r
  }

  /// Not checked yet: counts as iCloud wherever space on the device is promised.
  static func unseen(_ record: AssetRecord) -> AssetRecord {
    var r = record
    r.originalLocal = nil
    return r
  }

  @Test func freeableSplitsByWhereTheOriginalIs() {
    let records = [
      Make.asset("localShot", subtypes: Preset.screenshotSubtype, bytes: 1_000),
      Self.cloud(Make.asset("cloudShot", subtypes: Preset.screenshotSubtype, bytes: 2_000)),
      Self.unseen(Make.asset("newShot", subtypes: Preset.screenshotSubtype, bytes: 4_000)),
    ]
    let s = CleanupSummary.make(records: records, groups: [])
    #expect(s.freeableBytes == 7_000, "the full figure is kept for the iCloud line")
    #expect(s.freeableOnDevice == 1_000)
    #expect(s.freeableInCloud == 6_000, "not checked yet counts as iCloud")
    #expect(s[.screenshots] == CategoryTotal(count: 3, bytes: 7_000, onDeviceBytes: 1_000, inCloudBytes: 6_000))
    #expect(s.library.onDeviceBytes == 1_000 && s.library.inCloudBytes == 6_000)
  }

  @Test func unprobedVideosAddNoSquishSavingsAnywhere() {
    let local = Make.video("local", seconds: 120), cloud = Self.cloud(Make.video("cloud", seconds: 120))
    let s = CleanupSummary.make(records: [local, cloud], groups: [], probedVideos: [])
    #expect(s.bigVideoSavings == 0 && s.bigVideoSavingsOnDevice == 0)
    #expect(s.freeableOnDevice == 0 && s.freeableInCloud == 0)
    #expect(s[.bigVideos].count == 2, "still listed as big videos")
  }

  @Test func anUnprobedVideoThatIsADeletionCandidateCountsAtFullSize() {
    let keep = Make.video("keep", seconds: 120, phash: Make.hashA)
    var extra = Make.video("extra", seconds: 120, phash: Make.hashA2)
    extra.isFavorite = false
    let s = CleanupSummary.make(records: [keep, extra], groups: [["keep", "extra"]], probedVideos: [])
    let extraBytes = s.groups.first.map { $0.reclaimableBytes } ?? 0
    #expect(extraBytes > 0 && s.freeableOnDevice == extraBytes && s.bigVideoSavings == 0)
  }

  @Test func bigVideoSavingsCountOnDeviceOnlyForLocalVideos() {
    let local = Make.video("local", seconds: 120)
    let cloud = Self.cloud(Make.video("cloud", seconds: 120))
    let s = CleanupSummary.make(records: [local, cloud], groups: [], probedVideos: ["local", "cloud"])
    #expect(s.bigVideoSavings > 0)
    #expect(s.bigVideoSavingsOnDevice * 2 == s.bigVideoSavings)
    #expect(s.freeableOnDevice == s.bigVideoSavingsOnDevice)
    #expect(s.freeableInCloud == s.bigVideoSavings - s.bigVideoSavingsOnDevice)
  }

  @Test func duplicatesCountTheirLocalExtras() {
    let records = [
      Make.asset("keep", bytes: 500, phash: Make.hashA, favorite: true),
      Make.asset("extraLocal", bytes: 300, phash: Make.hashA2),
      Self.cloud(Make.asset("extraCloud", bytes: 200, phash: Make.hashA2)),
    ]
    let s = CleanupSummary.make(records: records, groups: [["keep", "extraLocal", "extraCloud"]])
    #expect(s.freeableOnDevice == 300)
    #expect(s.freeableInCloud == 200)
    #expect(s[.duplicates].onDeviceBytes == 300)
  }

  @Test func theQualityAnalysisSideIsTheBlurScoresSide() {
    #expect(AssetRecord.qualityAnalysisSide == BlurScore.analysisSide)
  }

  @Test func theHeadlineNeverExceedsTheSpaceInUse() {
    var s = CleanupSummary()
    s.freeableOnDevice = 39_570_000_000
    let used = 115_090_000_000 - 9_350_000_000
    #expect(s.onDeviceHeadline(deviceTotal: 115_090_000_000, deviceAvailable: 9_350_000_000) == 39_570_000_000)
    #expect(s.onDeviceHeadline(deviceTotal: 40_000_000_000, deviceAvailable: 9_350_000_000) == 30_650_000_000)
    #expect(s.onDeviceHeadline(deviceTotal: nil, deviceAvailable: nil) == 39_570_000_000)
    #expect(CleanupSummary.capped(200_000_000_000, deviceTotal: 115_090_000_000, deviceAvailable: 9_350_000_000) == used)
    #expect(CleanupSummary.capped(5, deviceTotal: 10, deviceAvailable: 20) == 0, "a nonsense reading caps at zero")
  }
}
