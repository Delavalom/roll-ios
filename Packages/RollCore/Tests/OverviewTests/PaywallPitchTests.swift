import Foundation
import Overview
import Ranking
import Store
import Testing

/// The paywall leads with the user's own number: the same on-device figure the taste scan (or Home) showed, from a
/// floor up, and the generic copy otherwise.
struct PaywallPitchTests {
  static let mb: Int64 = 1_000_000

  static func shots(_ count: Int, bytes: Int64, prefix: String = "s", local: Bool = true) -> [AssetRecord] {
    (0..<count).map { i in
      var r = Make.asset("\(prefix)\(i)", subtypes: Preset.screenshotSubtype, bytes: bytes)
      r.originalLocal = local
      return r
    }
  }

  @Test func atTheFloorThePitchCarriesTheNumberAsGiven() throws {
    let pitch = try #require(PaywallPitch.make(onDeviceBytes: PaywallPitch.minimumBytes,
                                               found: [FoundItem(kind: .screenshots, bytes: 100 * Self.mb)]))
    #expect(pitch.bytes == PaywallPitch.minimumBytes, "never a different number from the one passed in")
    #expect(pitch.subline == "All from screenshots.")
  }

  @Test func belowTheFloorFallsBackToTheGenericCopy() {
    #expect(PaywallPitch.make(onDeviceBytes: PaywallPitch.minimumBytes - 1,
                              found: [FoundItem(kind: .screenshots, bytes: 99 * Self.mb)]) == nil)
    #expect(PaywallPitch.make(onDeviceBytes: 0, found: []) == nil)
    #expect(PaywallPitch.make(onDeviceBytes: -5, found: []) == nil)
  }

  @Test func sublineNamesTheTopTwoCategoriesByBytes() throws {
    let found = [
      FoundItem(kind: .screenshots, bytes: 50 * Self.mb),
      FoundItem(kind: .duplicates, bytes: 900 * Self.mb),
      FoundItem(kind: .bigVideos, bytes: 300 * Self.mb),
      FoundItem(kind: .blurry, bytes: 10 * Self.mb),
    ]
    let pitch = try #require(PaywallPitch.make(onDeviceBytes: 1_260 * Self.mb, found: found))
    #expect(pitch.subline == "Mostly duplicates and similar shots, plus big videos Roll can squish.")
  }

  @Test func tiesKeepTheScanScreensOrder() throws {
    let found = [FoundItem(kind: .screenshots, bytes: 200 * Self.mb), FoundItem(kind: .blurry, bytes: 200 * Self.mb)]
    let pitch = try #require(PaywallPitch.make(onDeviceBytes: 400 * Self.mb, found: found))
    #expect(pitch.subline == "Mostly screenshots, plus blurry photos.")
  }

  @Test func emptyCategoriesAreIgnoredAndNoCategoryMeansNoSubline() throws {
    let found = [FoundItem(kind: .screenshots, bytes: 0), FoundItem(kind: .blurry, bytes: 150 * Self.mb)]
    #expect(try #require(PaywallPitch.make(onDeviceBytes: 150 * Self.mb, found: found)).subline
      == "All from blurry photos.")
    #expect(try #require(PaywallPitch.make(onDeviceBytes: 150 * Self.mb, found: [])).subline == nil)
  }

  // MARK: From a summary

  @Test func foundOnDeviceListsTheScanScreensCategoriesOnThisIPhoneOnly() {
    var dupA = Make.asset("a", bytes: 40 * Self.mb, phash: Make.hashA)
    dupA.isFavorite = true
    let dupB = Make.asset("b", bytes: 30 * Self.mb, phash: Make.hashA2)
    let records = Self.shots(3, bytes: 20 * Self.mb) + Self.shots(2, bytes: 500 * Self.mb, prefix: "c", local: false)
      + [dupA, dupB]
    let s = CleanupSummary.make(records: records, groups: [["a", "b"]])
    #expect(s.foundOnDevice == [FoundItem(kind: .screenshots, bytes: 60 * Self.mb),
                                FoundItem(kind: .duplicates, bytes: 30 * Self.mb)])
  }

  @Test func aLibraryInICloudOnlyGetsTheGenericCopy() {
    let s = CleanupSummary.make(records: Self.shots(10, bytes: 500 * Self.mb, local: false), groups: [])
    #expect(s.freeableInCloud == 5_000 * Self.mb)
    #expect(PaywallPitch.make(summary: s, deviceTotal: nil, deviceAvailable: nil) == nil,
            "iCloud bytes free iCloud space, not this iPhone's")
  }

  @Test func aSummaryPitchesItsOnDeviceHeadlineCappedLikeHome() throws {
    let s = CleanupSummary.make(records: Self.shots(4, bytes: 100 * Self.mb), groups: [])
    let uncapped = try #require(PaywallPitch.make(summary: s, deviceTotal: nil, deviceAvailable: nil))
    #expect(uncapped.bytes == s.onDeviceHeadline(deviceTotal: nil, deviceAvailable: nil))
    #expect(uncapped.bytes == 400 * Self.mb)
    let capped = try #require(PaywallPitch.make(summary: s, deviceTotal: 1_000 * Self.mb,
                                                deviceAvailable: 750 * Self.mb))
    #expect(capped.bytes == 250 * Self.mb, "the same number Home's header shows")
    #expect(PaywallPitch.make(summary: s, deviceTotal: 1_000 * Self.mb, deviceAvailable: 950 * Self.mb) == nil,
            "capped below the floor")
  }

  /// A scan that stopped early still showed its numbers ("Here's what Roll found so far"): the paywall repeats them.
  /// One that stopped before any results loaded showed nothing, so the paywall says nothing either.
  @Test func aPartialScanPitchesWhatItShowedAndAnEmptyOneFallsBack() throws {
    let partial = CleanupSummary.make(records: Self.shots(2, bytes: 80 * Self.mb), groups: [])
    #expect(try #require(PaywallPitch.make(summary: partial, deviceTotal: nil, deviceAvailable: nil)).bytes
      == 160 * Self.mb)
    #expect(PaywallPitch.make(summary: CleanupSummary(), deviceTotal: nil, deviceAvailable: nil) == nil)
  }

  // MARK: Without a number

  /// Outcome first (Praktika L1), and the privacy promise stays (PRODUCT_GUARDRAILS.md).
  @Test func theGenericHeaderLeadsWithTheOutcomeAndKeepsThePrivacyPromise() {
    let headline = PaywallPitch.genericHeadline.lowercased()
    #expect(headline.contains("space back"))
    #expect(headline.contains("without uploading"))
    #expect(PaywallPitch.genericSubline.contains("on your iPhone"))
  }

  /// ADR-0002 (no performance claims) and the guardrails' tone (never calls a library messy).
  @Test func theGenericCopyFollowsTheCopyRules() {
    let banned = ["boost", "free ram", "speed up", "faster", "optimiz", "clean your phone", "mess"]
    for text in [PaywallPitch.genericHeadline, PaywallPitch.genericSubline] {
      for word in banned { #expect(!text.lowercased().contains(word), "\(text) contains \(word)") }
    }
  }

  /// Roll Pro is pay once, and the price card says so. The header quotes no price (ours or a storage plan's) and
  /// names no billing period, so it can never contradict the card.
  @Test func theGenericCopyQuotesNoPriceAndNoBillingPeriod() {
    let banned = ["$", "icloud+", "subscri", "trial", "week", "month", "year", "annual", "renew", "cancel"]
    for text in [PaywallPitch.genericHeadline, PaywallPitch.genericSubline] {
      for word in banned { #expect(!text.lowercased().contains(word), "\(text) contains \(word)") }
    }
  }

  /// Fits the paywall's display title in about two lines on the smallest supported iPhone.
  @Test func theGenericHeadlineStaysShort() {
    #expect(PaywallPitch.genericHeadline.count <= 56)
  }
}
