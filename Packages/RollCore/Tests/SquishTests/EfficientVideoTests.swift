import AVFoundation
import Foundation
import Library
import Overview
import Store
import Synchronization
import Testing
@testable import Squish
import SquishBridge

private let MB: Int64 = 1_000_000

/// Device QA 2026-10-24: Squish offered a 1080p HEVC video (a copy Roll had made in an earlier squish) as "about
/// 12.9 MB → 5.6 MB, −56%", and the run refused it as not smaller. The size came from the bitrate table (10 Mbps at
/// 1080p), not the file. Once the format probe has measured a video (codec, real size, frame rate), the plan uses
/// those: an HEVC video that's already about as compact as Squish would make it isn't offered ("Already compact
/// (HEVC)"), while 4K → 1080p downscales, high-bitrate HEVC and H.264 still are.
struct EfficientVideoTests {
  /// A local 1080p (or `w`x`h`) video sized by the bitrate table, as the indexer stores it.
  static func video(_ id: String, seconds: Double = 10.32, w: Int = 1920, h: Int = 1080) -> AssetRecord {
    let table = Double(SizeEstimator.videoBitrate(pixelW: w, pixelH: h, fps: 30))
    return AssetRecord(id: id, mediaType: 2, subtypes: 0, pixelW: w, pixelH: h, duration: seconds,
                       estBytes: Int64(seconds * table / 8), signalsDone: true, source: .full, originalLocal: true)
  }

  /// The facts a probe reports for a file of `codec` at `mbps` over `seconds`.
  static func facts(_ codec: String, mbps: Double, seconds: Double = 10.32, fps: Double = 30) -> VideoProbeFacts {
    VideoProbeFacts(codec: codec, bytes: Int64(seconds * mbps * 1_000_000 / 8), fps: fps)
  }

  @Test func theDeviceQACaseIsNoLongerOffered() {
    let copy = Self.video("copy")
    #expect(copy.estBytes == 12_900_000, "the table's guess: about 12.9 MB")
    let promised = SquishPlanner.offer(for: copy, keep4K: false)?.estimatedOutputBytes ?? 0
    #expect(abs(promised - 5_600_000) < 50_000, "the fake promise: about 5.6 MB")
    // What Roll's own HEVC copy measures: about the bitrate Squish produces.
    let measured = Self.facts("hvc1", mbps: 4.6)
    #expect(SquishPlanner.offer(for: copy, keep4K: false, facts: measured) == nil)
  }

  @Test func hevcAtCameraBitratesAtOrBelow1080pIsNotOffered() {
    // Apple's camera HEVC: 1080p30 about 8 Mbps (60 MB/min), 1080p60 about 12 Mbps (90 MB/min), 720p30 about 5.3 Mbps.
    let hd30 = Self.facts("hvc1", mbps: 8)
    let hd60 = Self.facts("hev1", mbps: 12, fps: 60)
    let long = Self.video("long", seconds: 120)
    #expect(SquishPlanner.offer(for: Self.video("hd30"), keep4K: false, facts: hd30) == nil)
    #expect(SquishPlanner.offer(for: Self.video("hd60"), keep4K: false, facts: hd60) == nil)
    #expect(SquishPlanner.offer(for: long, keep4K: false, facts: Self.facts("hvc1", mbps: 8, seconds: 120)) == nil,
            "over 50 MB, but already compact")
  }

  @Test func hevc4KIsOfferedWithItsDownscaleAndItsRealSize() throws {
    let uhd = Self.video("uhd", seconds: 10, w: 3840, h: 2160)
    let measured = Self.facts("hvc1", mbps: 22.7, seconds: 10)  // 4K30 camera HEVC, 170 MB/min
    let item = try #require(SquishPlanner.offer(for: uhd, keep4K: false, facts: measured))
    #expect(item.downscale == Downscale(fromW: 3840, fromH: 2160, toW: 1920, toH: 1080))
    #expect(item.estimatedBytes == measured.bytes, "the measured size, not the table's 45 Mbps")
    #expect(item.savingsFraction >= SquishPlanner.minimumSavingsFraction)
    // Kept at 4K, HEVC to HEVC gains nothing worth a squish.
    #expect(SquishPlanner.offer(for: uhd, keep4K: true, facts: measured) == nil)
  }

  @Test func highBitrateHEVCIsStillOffered() throws {
    let item = try #require(SquishPlanner.offer(for: Self.video("hot"), keep4K: false, facts: Self.facts("hvc1", mbps: 20)))
    #expect(item.downscale == nil)
    #expect(item.savingsFraction >= SquishPlanner.minimumSavingsFraction)
    #expect(item.estimatedBytes == 25_800_000)
  }

  @Test func h264At1080pIsOfferedByItsRealBitrate() throws {
    // 1080p30 camera H.264: about 17 Mbps (130 MB/min).
    let measured = Self.facts("avc1", mbps: 17)
    let item = try #require(SquishPlanner.offer(for: Self.video("avc"), keep4K: false, facts: measured))
    #expect(item.estimatedBytes == measured.bytes)
    #expect(item.savingsFraction >= SquishPlanner.minimumSavingsFraction)
    // A low-bitrate H.264 (saved from a messaging app) has nothing left to give.
    #expect(SquishPlanner.offer(for: Self.video("small"), keep4K: false, facts: Self.facts("avc1", mbps: 5)) == nil)
  }

  @Test func factsWithoutMeasurementsKeepTodaysEstimate() {
    let r = Self.video("v")
    #expect(SquishPlanner.offer(for: r, keep4K: false, facts: VideoProbeFacts())
              == SquishPlanner.offer(for: r, keep4K: false))
  }

  @Test func theCatalogListsCompactVideosWithTheirReason() {
    let records = [Self.video("compact"), Self.video("avc"), Self.video("unprobed"),
                   Self.video("uhd", seconds: 10, w: 3840, h: 2160), Self.video("lowAVC")]
    let facts = ["compact": Self.facts("hvc1", mbps: 4.6), "avc": Self.facts("avc1", mbps: 17),
                 "uhd": Self.facts("hvc1", mbps: 22.7, seconds: 10), "lowAVC": Self.facts("avc1", mbps: 5)]
    let catalog = SquishCatalog.make(records: records, keep4K: false, excluding: [], videoFacts: facts)
    #expect(Set(catalog.items.map(\.assetID)) == ["avc", "uhd", "unprobed"])
    #expect(Set(catalog.defaultSelection) == ["avc", "uhd"], "a video not probed yet is listed, not selected")
    let compact = catalog.notSquishable.sorted { $0.assetID < $1.assetID }
    #expect(compact == [
      NotSquishable(assetID: "compact", estimatedBytes: facts["compact"]!.bytes!, reason: SquishRefusal.alreadyCompactHEVC),
      NotSquishable(assetID: "lowAVC", estimatedBytes: facts["lowAVC"]!.bytes!, reason: SquishRefusal.alreadyCompact),
    ])
    #expect(SquishRefusal.alreadyCompactHEVC == "Already compact (HEVC)")
    #expect(catalog.items.first { $0.assetID == "avc" }?.estimatedBytes == facts["avc"]!.bytes)
  }

  @Test func homeCountsNoSavingsForCompactVideos() throws {
    let compact = Self.video("compact", seconds: 120), avc = Self.video("avc", seconds: 120)
    let facts = ["compact": Self.facts("hvc1", mbps: 8, seconds: 120), "avc": Self.facts("avc1", mbps: 17, seconds: 120)]
    let summary = CleanupSummary.make(records: [compact, avc], groups: [], probedVideos: ["compact", "avc"],
                                      videoFacts: facts)
    let avcSavings = try #require(SquishPlanner.offer(for: avc, keep4K: false, facts: facts["avc"])).estimatedSavings
    #expect(summary.bigVideoSavings == avcSavings)
  }

  final class MeasuringProbe: VideoFormatProbing {
    let results: [String: VideoProbeResult]
    init(_ results: [String: VideoProbeResult]) { self.results = results }
    func verdict(for assetID: String) async -> VideoFormatVerdict? { results[assetID]?.verdict }
    func probe(for assetID: String) async -> VideoProbeResult? { results[assetID] }
  }

  /// Before the probe, the compact video is offered (not selected); once its facts land it moves to "Not squishable
  /// yet", and that holds after a relaunch without probing again.
  @Test func theProbeStoresWhatItMeasured() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.video("compact"), Self.video("avc")])
    let before = try await SquishCatalog.load(repositories: repo, keep4K: false)
    #expect(Set(before.items.map(\.assetID)) == ["compact", "avc"] && before.defaultSelection.isEmpty)

    let probe = MeasuringProbe([
      "compact": VideoProbeResult(verdict: .squishable, facts: Self.facts("hvc1", mbps: 4.6)),
      "avc": VideoProbeResult(verdict: .squishable, facts: Self.facts("avc1", mbps: 17)),
    ])
    try await SquishFormatScreen(probe: probe, repositories: repo).run()
    let after = try await SquishCatalog.load(repositories: repo, keep4K: false)
    #expect(after.items.map(\.assetID) == ["avc"] && after.defaultSelection == ["avc"])
    #expect(after.notSquishable.map(\.reason) == [SquishRefusal.alreadyCompactHEVC])
    #expect(try await repo.videoProbeFacts()["compact"] == Self.facts("hvc1", mbps: 4.6))
  }

  @Test func aProbeThatOnlyKnowsTheVerdictRecordsNoFacts() async throws {
    let probe = SquishTruthTests.FakeProbe(["v": .squishable])
    let result = await probe.probe(for: "v")
    #expect(result == VideoProbeResult(verdict: .squishable, facts: nil))
  }

  @Test func measuringAFileReadsItsCodecSizeAndFrameRate() async throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let avc = dir.appendingPathComponent("avc.mov")
    try await Fixtures.makeVideo(at: avc, seconds: 2, fps: 15)
    let facts = try await VideoProbeFacts.measure(AVURLAsset(url: avc))
    #expect(facts.codec == "avc1" && !facts.isHEVC)
    #expect(facts.bytes == (try Fixtures.fileSize(avc)))
    #expect(abs((facts.fps ?? 0) - 15) < 0.5)

    guard Fixtures.hasHEVCHardwareEncoder else { return }
    let hevc = dir.appendingPathComponent("hevc.mov")
    try await Fixtures.makeVideo(at: hevc, seconds: 2, fps: 15, codec: .hevc)
    #expect(try await VideoProbeFacts.measure(AVURLAsset(url: hevc)).isHEVC)
  }
}
