import Foundation
import Store
import Synchronization
import Testing
@testable import Squish
import SquishBridge

/// Squish offers what it can deliver: only items on this iPhone start selected, and Dolby Vision (and ProRes / Apple
/// Log) videos are found before selection, by reading the local file's format, and kept out of the list and the
/// savings ("HDR video kept as is").
struct SquishTruthTests {
  static func video(_ id: String, local: Bool, seconds: Double = 120, created: Double = 0) -> AssetRecord {
    AssetRecord(id: id, mediaType: 2, subtypes: 0, created: created, pixelW: 1920, pixelH: 1080, duration: seconds,
                estBytes: Int64(seconds * 10_000_000 / 8), cloudOnly: !local, signalsDone: true,
                source: local ? .full : .preview, originalLocal: local)
  }

  static func photo(_ id: String, local: Bool) -> AssetRecord {
    AssetRecord(id: id, mediaType: 1, subtypes: 0, pixelW: 4000, pixelH: 3000, uti: "public.jpeg", estBytes: 10_800_000,
                cloudOnly: !local, signalsDone: true, source: local ? .full : .preview, originalLocal: local)
  }

  @Test func onlyLocalItemsStartSelectedAndVideosOnlyOnceTheirFormatPassed() {
    let records = [Self.video("lv", local: true), Self.video("cv", local: false),
                   Self.photo("lp", local: true), Self.photo("cp", local: false)]
    let unprobed = SquishCatalog.make(records: records, keep4K: false, excluding: [])
    #expect(Set(unprobed.items.map(\.assetID)) == ["lv", "cv", "lp", "cp"], "listed right away")
    #expect(Set(unprobed.defaultSelection) == ["lp"], "the video waits for its probe")
    #expect(unprobed.cloudOnly == ["cv", "cp"])
    let probed = SquishCatalog.make(records: records, keep4K: false, excluding: [], probedVideos: ["lv", "cv"])
    #expect(Set(probed.defaultSelection) == ["lv", "lp"], "an iCloud video never starts selected")
  }

  /// Device QA D3: a photo whose preview was on the iPhone (`cloudOnly` false) but whose original is only in iCloud
  /// was listed without "in iCloud" and not selected; squishing it failed with "needs download". Every offered item
  /// is now either on this iPhone or marked as in iCloud, by the same original-resource check.
  @Test func theICloudMarkFollowsTheOriginalNotThePreview() {
    var previewLocal = Self.photo("pl", local: true)
    previewLocal.originalLocal = false
    var unchecked = Self.photo("uc", local: true)
    unchecked.originalLocal = nil
    let catalog = SquishCatalog.make(records: [Self.photo("lp", local: true), previewLocal, unchecked],
                                     keep4K: false, excluding: [])
    #expect(Set(catalog.items.map(\.assetID)) == ["lp", "pl", "uc"])
    #expect(catalog.cloudOnly == ["pl", "uc"], "not checked yet counts as iCloud")
    #expect(catalog.defaultSelection == ["lp"])
    for item in catalog.items {
      #expect(catalog.defaultSelection.contains(item.assetID) != catalog.cloudOnly.contains(item.assetID))
    }
  }

  /// Device QA 2026-10-24: 5 selected, 3 of them only in iCloud, downloads off. The button and the confirm sheet said
  /// "Squish 5 · saves about 55.3 MB", the run refused the 3 with needsDownload and about 9 MB was saved. While
  /// downloads are off an iCloud item can't be selected, and a selection made with them on drops out of the count,
  /// the savings and the queue.
  @Test func iCloudItemsCountOnlyWhileDownloadsAreAllowed() {
    let records = [Self.video("lv", local: true), Self.video("cv", local: false, seconds: 300),
                   Self.photo("lp", local: true), Self.photo("cp", local: false), Self.video("cv2", local: false)]
    let catalog = SquishCatalog.make(records: records, keep4K: false, excluding: [], probedVideos: ["lv", "cv", "cv2"])
    let all = Set(catalog.items.map(\.assetID))
    #expect(all.count == 5 && catalog.cloudOnly == ["cv", "cp", "cv2"])

    let off = catalog.runnable(all, downloadsAllowed: false)
    #expect(off.map(\.assetID) == catalog.items.map(\.assetID).filter { ["lv", "lp"].contains($0) },
            "most bytes first, local only")
    #expect(!catalog.canSquish("cv", downloadsAllowed: false) && catalog.canSquish("lv", downloadsAllowed: false))

    let on = catalog.runnable(all, downloadsAllowed: true)
    #expect(on.map(\.assetID) == catalog.items.map(\.assetID), "with downloads allowed every selected item counts")
    #expect(catalog.items.allSatisfy { catalog.canSquish($0.assetID, downloadsAllowed: true) })
    #expect(on.reduce(0) { $0 + $1.estimatedSavings } > off.reduce(0) { $0 + $1.estimatedSavings })

    #expect(catalog.runnable(["lp", "cp", "gone"], downloadsAllowed: true).map(\.assetID)
              == catalog.items.map(\.assetID).filter { ["lp", "cp"].contains($0) }, "only offered items, in list order")
    #expect(catalog.runnable(Set(catalog.defaultSelection), downloadsAllowed: false).map(\.assetID)
              == catalog.defaultSelection, "the default selection never needs a download")
  }

  /// Device QA: every selected original in iCloud, downloads on, no Wi-Fi: the alert was titled "Something went wrong".
  /// The button now says Wi-Fi is needed, and runs whatever is on this iPhone when there is something.
  @Test func theSquishButtonSaysWiFiIsNeededInsteadOfSomethingWentWrong() {
    let records = [Self.photo("lp", local: true), Self.photo("cp", local: false), Self.photo("cp2", local: false)]
    let catalog = SquishCatalog.make(records: records, keep4K: false, excluding: [])
    #expect(catalog.start(["cp", "cp2"], downloadsAllowed: true, onWiFi: false) == .blocked(.needsWiFi))
    #expect(SquishNotice.needsWiFi.title == "Wi-Fi needed")
    #expect(SquishNotice.needsWiFi.message.contains("Wi-Fi only"))
    #expect(!SquishNotice.needsWiFi.title.contains("went wrong"))

    let wifi = catalog.start(["cp", "cp2"], downloadsAllowed: true, onWiFi: true)
    guard case .run(let ids, let network) = wifi else { Issue.record("expected a run"); return }
    #expect(Set(ids) == ["cp", "cp2"] && network)

    #expect(catalog.start(["lp", "cp"], downloadsAllowed: true, onWiFi: false) == .run(ids: ["lp"], allowNetwork: false),
            "the item on this iPhone still runs; the iCloud one drops out")
    #expect(catalog.start(["cp"], downloadsAllowed: false, onWiFi: true) == .nothing,
            "with downloads off an iCloud item isn't runnable at all (its row says so)")
    #expect(catalog.start([], downloadsAllowed: true, onWiFi: false) == .nothing)
  }

  final class FakeProbe: VideoFormatProbing {
    let verdicts: Mutex<[String: VideoFormatVerdict]>
    private let calls = Mutex<[String]>([])
    private let active = Mutex((now: 0, max: 0))
    let delay: Duration
    init(_ verdicts: [String: VideoFormatVerdict], delay: Duration = .zero) {
      self.verdicts = Mutex(verdicts); self.delay = delay
    }
    var probed: [String] { calls.withLock { $0 } }
    var maxConcurrent: Int { active.withLock { $0.max } }
    func verdict(for assetID: String) async -> VideoFormatVerdict? {
      calls.withLock { $0.append(assetID) }
      active.withLock { $0.now += 1; $0.max = max($0.max, $0.now) }
      if delay > .zero { try? await Task.sleep(for: delay) }
      active.withLock { $0.now -= 1 }
      return verdicts.withLock { $0[assetID] }
    }
  }

  @Test func dolbyVisionIsFoundBeforeSelectionAndLeftOutOfTheSavings() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.video("dv", local: true, created: 3), Self.video("plain", local: true, created: 2),
                                 Self.video("cloud", local: false, created: 1), Self.photo("photo", local: true)])
    let probe = FakeProbe(["dv": .dolbyVision, "plain": .squishable, "cloud": .dolbyVision])
    let screen = SquishFormatScreen(probe: probe, repositories: repo)

    #expect(try await screen.run() == 1)
    #expect(Set(probe.probed) == ["dv", "plain"], "only local videos are probed; photos and iCloud videos aren't")
    let catalog = try await SquishCatalog.load(repositories: repo, keep4K: false)
    #expect(!catalog.items.map(\.assetID).contains("dv"))
    #expect(catalog.hdrKept.map(\.assetID) == ["dv"])
    #expect(catalog.hdrKept.first?.reason == SquishRefusal.hdrVideoKept)
    #expect(!catalog.notSquishable.map(\.assetID).contains("dv"), "listed once, under HDR video kept as is")
    #expect(Set(catalog.defaultSelection) == ["plain", "photo"])
    #expect(try await repo.passedVideoProbes() == ["plain"])

    #expect(try await screen.run() == 0)
    #expect(probe.probed.count == 2, "results are stored: nothing is probed twice")
    let relaunched = SquishFormatScreen(probe: probe, repositories: repo)
    #expect(try await relaunched.run() == 0)
    #expect(probe.probed.count == 2, "a new launch reuses the stored results")
  }

  @Test func aVideoThatCouldNotBeReadIsTriedAgain() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.video("v", local: true)])
    let probe = FakeProbe([:])  // nil: not readable right now
    let screen = SquishFormatScreen(probe: probe, repositories: repo)
    try await screen.run()
    probe.verdicts.withLock { $0["v"] = .squishable }
    try await screen.run()
    #expect(probe.probed == ["v", "v"])
    #expect(try await repo.passedVideoProbes() == ["v"])
  }

  @Test func overlappingRunsShareOneProbingTask() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets((0..<4).map { Self.video("v\($0)", local: true, created: Double($0)) })
    let probe = FakeProbe(Dictionary(uniqueKeysWithValues: (0..<4).map { ("v\($0)", .squishable) }),
                          delay: .milliseconds(20))
    let screen = SquishFormatScreen(probe: probe, repositories: repo)
    async let a = screen.run()
    async let b = screen.run()
    _ = try await (a, b)
    #expect(probe.maxConcurrent == 1)
    #expect(probe.probed.count == 4, "each video once, not once per caller")
  }

  @Test func proResAndLogAreRefusedWithTheFormatReason() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.video("prores", local: true), Self.video("log", local: true, created: 1)])
    let screen = SquishFormatScreen(probe: FakeProbe(["prores": .proRes, "log": .appleLog]), repositories: repo)
    #expect(try await screen.run() == 2)
    let catalog = try await SquishCatalog.load(repositories: repo, keep4K: false)
    #expect(catalog.items.isEmpty && catalog.hdrKept.isEmpty)
    #expect(Set(catalog.notSquishable.map(\.reason)) == [SquishRefusal.text(for: .unsupportedFormat)])
  }

  @Test func verdictsFollowTheExportTimeCheck() {
    #expect(VideoFormatVerdict(nil) == .squishable)
    #expect(VideoFormatVerdict(.dolbyVision) == .dolbyVision)
    #expect(VideoFormatVerdict(.proRes) == .proRes)
    #expect(VideoFormatVerdict(.appleLog) == .appleLog)
  }

  /// Probes `hung` ids without ever calling back (a PhotoKit request whose handler never fires); others answer
  /// `.squishable`. Continuations are held so nothing leaks mid-test.
  final class HangingProbe: VideoFormatProbing {
    let hung: Set<String>
    private let calls = Mutex<[String]>([])
    private let waiting = Mutex<[CheckedContinuation<VideoFormatVerdict?, Never>]>([])
    init(hung: Set<String>) { self.hung = hung }
    var probed: [String] { calls.withLock { $0 } }
    func verdict(for assetID: String) async -> VideoFormatVerdict? {
      calls.withLock { $0.append(assetID) }
      guard hung.contains(assetID) else { return .squishable }
      return await withCheckedContinuation { c in waiting.withLock { $0.append(c) } }
    }
    func release() { waiting.withLock { $0 }.forEach { $0.resume(returning: .squishable) } }
  }

  @Test func aProbeThatNeverAnswersTimesOutAndWaitsForTheNextLaunch() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.video("hung", local: true, created: 2), Self.video("ok", local: true, created: 1)])
    let probe = HangingProbe(hung: ["hung"])
    let screen = SquishFormatScreen(probe: probe, repositories: repo, timeout: .milliseconds(50))
    let first = try await screen.screen()
    #expect(first == SquishFormatScreen.Screening(refused: 0, recorded: 1, timedOut: 1))
    #expect(try await repo.passedVideoProbes() == ["ok"], "a timeout records nothing: the video isn't selected")
    _ = try await screen.screen()
    #expect(probe.probed.filter { $0 == "hung" }.count == 1, "not asked again this launch")
    let relaunched = SquishFormatScreen(probe: probe, repositories: repo, timeout: .milliseconds(50))
    _ = try await relaunched.screen()
    #expect(probe.probed.filter { $0 == "hung" }.count == 2, "tried again next launch")
    probe.release()
    #expect(try await repo.passedVideoProbes() == ["ok"], "a late answer is ignored")
  }

  @Test func repeatedProbeTimeoutsEndThePass() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    let ids = (0..<5).map { "v\($0)" }
    try await repo.upsertAssets(ids.enumerated().map { Self.video($1, local: true, created: Double($0)) })
    let probe = HangingProbe(hung: Set(ids))
    let screen = SquishFormatScreen(probe: probe, repositories: repo, timeout: .milliseconds(20))
    #expect(try await screen.screen().timedOut == SquishFormatScreen.maxConsecutiveTimeouts)
    #expect(probe.probed.count == SquishFormatScreen.maxConsecutiveTimeouts)
    probe.release()
  }

  @Test func aCatalogTheCallerAlreadyLoadedIsUsedAsIs() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.video("a", local: true, created: 2), Self.video("b", local: true, created: 1)])
    let probe = FakeProbe(["a": .squishable, "b": .squishable])
    let screen = SquishFormatScreen(probe: probe, repositories: repo)
    let catalog = SquishCatalog.make(records: [Self.video("a", local: true)], keep4K: false, excluding: [])
    #expect(try await screen.screen(catalog: catalog).recorded == 1)
    #expect(probe.probed == ["a"])
  }
}
