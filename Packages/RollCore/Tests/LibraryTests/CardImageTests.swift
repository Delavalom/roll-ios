import CoreGraphics
import Synchronization
import Testing
@testable import Library

/// Swipe cards and their full-screen view (device QA 2026-10-24: blank cards on a 98% iCloud-only library, so the iOS
/// delete prompt was the first time the photo was seen). A card shows the best image on the device, downloads only on
/// Wi-Fi and only when nothing local can be shown, and a card with nothing on screen can't be decided on.
struct CardImageTests {
  static func image(_ side: Int) -> CGImage { ThumbnailPreviewTests.image(side) }

  /// Answers each (side, spec) from a table and records every request in order. It answers even when the task was
  /// cancelled, so the loader's own cancellation checks are what the tests exercise.
  final class FakeSource: CardImageSource {
    let answers: [ImageRequestSpec: [Int: ThumbnailResult]]
    let calls = Mutex<[(side: Int, spec: ImageRequestSpec)]>([])
    /// Runs before the download answers (a test cancels the task here).
    let onDownload: @Sendable () -> Void

    init(_ answers: [ImageRequestSpec: [Int: ThumbnailResult]], onDownload: @escaping @Sendable () -> Void = {}) {
      self.answers = answers
      self.onDownload = onDownload
    }

    func image(for id: String, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult {
      calls.withLock { $0.append((side, spec)) }
      if spec.allowsNetwork { onDownload() }
      return answers[spec]?[side] ?? .failed
    }

    var specs: [ImageRequestSpec] { calls.withLock { $0.map(\.spec) } }
    var downloads: [Int] { calls.withLock { $0.filter(\.spec.allowsNetwork).map(\.side) } }
  }

  /// Never answers until its task is cancelled (a PhotoKit request that hangs), then says so.
  final class HangingSource: CardImageSource {
    func image(for id: String, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult {
      try? await Task.sleep(for: .seconds(60))
      return .cancelled
    }
  }

  /// Every state the loader reported, and how often it asked about Wi-Fi.
  @MainActor final class Recorder {
    var states: [CardImage] = []
    var wifiChecks = 0
    func run(_ request: CardImageRequest, _ source: some CardImageSource, wifi: Bool,
             timeout: Duration = CardImageLoader.lookupTimeout) async {
      await CardImageLoader.load(id: "a", request: request, source: source, lookupTimeout: timeout,
                                 onWiFi: { self.wifiChecks += 1; return wifi }) { self.states.append($0) }
    }
    var names: [String] { states.map(\.name) }
  }

  // MARK: request options

  @Test func requestOptionsKeepTheNetworkOffUnlessItsADownload() {
    #expect(ImageRequestSpec.localSharp == ImageRequestSpec(delivery: .highQuality, allowsNetwork: false))
    #expect(ImageRequestSpec.localBest == ImageRequestSpec(delivery: .opportunistic, allowsNetwork: false),
            "opportunistic and offline: the local preview the Indexer analyses")
    #expect(ImageRequestSpec.download == ImageRequestSpec(delivery: .highQuality, allowsNetwork: true),
            "one delivery, network on (the caller checked Wi-Fi)")
    // The Indexer's flags keep their meaning.
    #expect(ImageRequestSpec(allowNetwork: false, previews: true) == .localBest)
    #expect(ImageRequestSpec(allowNetwork: false, previews: false) == .localSharp)
    #expect(ImageRequestSpec(allowNetwork: true, previews: true) == .download)
  }

  @Test func aCardTriesSharpSizesThenTheBestLocalImageAtTheSmallestSize() async {
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .preview(Self.image(120))]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(source.calls.withLock { $0.map(\.side) } == [512, 300])
    #expect(source.specs == [.localSharp, .localBest])
    #expect(CardImageRequest.card.sides == [512, 300] && CardImageRequest.card.downloadBelow == nil)
    #expect(CardImageRequest.fullScreen.sides.first == 2000)
  }

  // MARK: what a card shows

  @Test func aLocalImageShowsAtOnceWithoutAskingAboutWiFi() async {
    let source = FakeSource([.localSharp: [512: .image(Self.image(512))]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["local"])
    #expect(await recorder.wifiChecks == 0)
    #expect(source.downloads.isEmpty)
    #expect(await recorder.states.last?.gate == .decide)
  }

  @Test func anICloudOnlyCardShowsItsLocalPreviewAndNeverDownloads() async {
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .preview(Self.image(120))]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["preview"])
    #expect(source.downloads.isEmpty, "a preview on screen is enough for a card: no download")
    #expect(await recorder.wifiChecks == 0)
    #expect(await recorder.states.last?.gate == .decide)
  }

  @Test func withNothingLocalACardDownloadsOnWiFiWithAVisibleLoadingState() async {
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .inCloud],
                             .download: [512: .image(Self.image(512))]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["downloading(nil)", "downloaded"])
    #expect(source.downloads == [512])
    let gates = await recorder.states.map(\.gate)
    #expect(gates == [.skipOnly, .decide], "nothing on screen while it downloads: it can be skipped, not decided")
  }

  @Test func withNothingLocalAndNoWiFiTheCardSaysSoAndCantBeDecided() async {
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .inCloud]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: false)
    #expect(await recorder.names == ["unavailable(needsWiFi)"])
    #expect(source.downloads.isEmpty, "no download off Wi-Fi")
    #expect(await recorder.states.last?.gate == .skipOnly)
  }

  @Test func aFailedDownloadIsUnavailableNotBlank() async {
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .inCloud], .download: [512: .failed]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["downloading(nil)", "unavailable(failed)"])
    #expect(await recorder.states.last?.gate == .skipOnly)
  }

  @Test func aLocalErrorIsUnavailableWithoutADownload() async {
    // Not "in iCloud": the asset is gone or Photos failed. Saying "needs Wi-Fi" would be a guess.
    let source = FakeSource([.localSharp: [512: .failed], .localBest: [300: .failed]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["unavailable(failed)"])
    #expect(source.downloads.isEmpty)
  }

  @Test func inICloudWinsOverAFailureAtAnotherSizeSoItStillDownloadsOnWiFi() async {
    // 512 px: in iCloud; 300 px: an error. The card is still an iCloud photo, not a lost one.
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .failed],
                             .download: [512: .image(Self.image(512))]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["downloading(nil)", "downloaded"])
    #expect(source.downloads == [512])
    // Off Wi-Fi it says why: Wi-Fi, not "can't show".
    let offline = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .failed]])
    let other = await Recorder()
    await other.run(.card, offline, wifi: false)
    #expect(await other.names == ["unavailable(needsWiFi)"])
  }

  @Test func aRequestPhotosCancelsOnItsOwnIsUnavailableAndSkippable() async {
    // PHImageCancelledKey without a task cancel: the card must not stay loading (gate .wait, no Skip).
    let source = FakeSource([.localSharp: [512: .cancelled], .localBest: [300: .cancelled]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["unavailable(failed)"])
    #expect(await recorder.states.last?.gate == .skipOnly)
    #expect(source.downloads.isEmpty)
  }

  @Test func aDownloadPhotosCancelsOnItsOwnIsUnavailable() async {
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .inCloud], .download: [512: .cancelled]])
    let recorder = await Recorder()
    await recorder.run(.card, source, wifi: true)
    #expect(await recorder.names == ["downloading(nil)", "unavailable(failed)"])
    #expect(await recorder.states.last?.gate == .skipOnly)
  }

  @Test func aLookupThatHangsTimesOutAndCanBeSkipped() async {
    let recorder = await Recorder()
    let started = ContinuousClock.now
    await recorder.run(.card, HangingSource(), wifi: true, timeout: .milliseconds(50))
    #expect(await recorder.names == ["unavailable(timedOut)"])
    #expect(await recorder.states.last?.gate == .skipOnly, "still unseen: skippable, never decidable")
    #expect(ContinuousClock.now - started < .seconds(5), "the hanging request was cancelled, not awaited")
    #expect(CardImageLoader.lookupTimeout == .seconds(8))
  }

  @Test func theTimeoutCoversAllSizesNotEachOne() async {
    // 512 px answers "in iCloud" in time, then 300 px hangs: the deadline is shared, and "in iCloud" still wins.
    final class SlowSecond: CardImageSource {
      func image(for id: String, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult {
        if side == 512 { return .inCloud }
        try? await Task.sleep(for: .seconds(60))
        return .cancelled
      }
    }
    let recorder = await Recorder()
    await recorder.run(.card, SlowSecond(), wifi: false, timeout: .milliseconds(50))
    #expect(await recorder.names == ["unavailable(needsWiFi)"])
  }

  // MARK: full screen

  @Test func fullScreenUpgradesASmallLocalImageOnWiFiAndKeepsShowingItMeanwhile() async {
    let source = FakeSource([.localSharp: [2000: .inCloud, 512: .inCloud], .localBest: [300: .preview(Self.image(120))],
                             .download: [2000: .image(Self.image(2000))]])
    let recorder = await Recorder()
    await recorder.run(.fullScreen, source, wifi: true)
    #expect(await recorder.names == ["preview", "downloading(image)", "downloaded"])
    #expect(source.downloads == [2000])
    #expect(await recorder.states.allSatisfy { $0.gate == .decide }, "the preview stays on screen while it downloads")
  }

  @Test func fullScreenOffWiFiKeepsThePreview() async {
    let source = FakeSource([.localSharp: [2000: .inCloud, 512: .inCloud], .localBest: [300: .preview(Self.image(120))]])
    let recorder = await Recorder()
    await recorder.run(.fullScreen, source, wifi: false)
    #expect(await recorder.names == ["preview"])
    #expect(source.downloads.isEmpty)
  }

  @Test func fullScreenAFailedUpgradeFallsBackToWhatWasShown() async {
    let source = FakeSource([.localSharp: [2000: .inCloud, 512: .image(Self.image(512))], .download: [2000: .failed]])
    let recorder = await Recorder()
    await recorder.run(.fullScreen, source, wifi: true)
    #expect(await recorder.names == ["local", "downloading(image)", "local"])
  }

  @Test func fullScreenDoesntDownloadWhenTheLocalImageIsLargeEnough() async {
    let source = FakeSource([.localSharp: [2000: .image(Self.image(2000))]])
    let recorder = await Recorder()
    await recorder.run(.fullScreen, source, wifi: true)
    #expect(await recorder.names == ["local"])
    #expect(await recorder.wifiChecks == 0)
  }

  // MARK: cancellation (a card swiped away)

  @Test func aCardSwipedAwayBeforeItLoadsReportsNothingAndDownloadsNothing() async {
    // The task is cancelled before it starts; the source still answers with an image.
    let source = FakeSource([.localSharp: [512: .image(Self.image(512))]])
    let recorder = await Recorder()
    let task = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      await recorder.run(.card, source, wifi: true)
    }
    await task.value
    #expect(await recorder.states.isEmpty)
    #expect(source.calls.withLock { $0.count } <= 1)
    #expect(source.downloads.isEmpty)
  }

  @Test func aCardSwipedAwayMidDownloadReportsNothingMore() async {
    // The download cancels the task that runs it, like a swipe cancelling the card's load, and the source still
    // returns the image: only the loader's own check keeps it from landing.
    let source = FakeSource([.localSharp: [512: .inCloud], .localBest: [300: .inCloud],
                             .download: [512: .image(Self.image(512))]],
                            onDownload: { withUnsafeCurrentTask { $0?.cancel() } })
    let recorder = await Recorder()
    await Task { await recorder.run(.card, source, wifi: true) }.value
    #expect(await recorder.names == ["downloading(nil)"], "a cancelled card never lands")
    #expect(source.downloads == [512])
  }

  // MARK: prefetch window

  @Test func prefetchLoadsTheTopCardAndTheNextThreeAndCancelsTheRest() {
    let first = CardPrefetch.plan(loading: [], stack: ["a", "b", "c", "d", "e", "f"])
    #expect(first.start == ["a", "b", "c", "d"], "top first")
    #expect(first.cancel.isEmpty)
    // "a" swiped away: "e" joins the window, "a" is cancelled.
    let next = CardPrefetch.plan(loading: ["a", "b", "c", "d"], stack: ["b", "c", "d", "e", "f"])
    #expect(next.start == ["e"])
    #expect(next.cancel == ["a"])
    // An undo brings "a" back on top: it loads again, "e" leaves the window.
    let undo = CardPrefetch.plan(loading: ["b", "c", "d", "e"], stack: ["a", "b", "c", "d", "e"])
    #expect(undo.start == ["a"] && undo.cancel == ["e"])
    #expect(CardPrefetch.plan(loading: ["x"], stack: []).cancel == ["x"])
  }

  @Test func retryLoadsTheWindowsUnavailableCardsAgain() {
    let image = Self.image(512)
    let states: [String: CardImage] = ["a": .local(image, isPreview: false), "b": .unavailable(.needsWiFi),
                                       "c": .loading, "d": .unavailable(.timedOut), "e": .unavailable(.failed)]
    #expect(CardPrefetch.retry(states, stack: ["a", "b", "c", "d", "e"]) == ["b", "d"],
            "unavailable cards in the window only (\"e\" is outside it), top first")
    #expect(CardPrefetch.retry(states, stack: []).isEmpty)
  }
}

extension CardImage {
  /// A short name for comparing sequences.
  var name: String {
    switch self {
    case .loading: "loading"
    case .local(_, let isPreview): isPreview ? "preview" : "local"
    case .downloading(let showing): showing == nil ? "downloading(nil)" : "downloading(image)"
    case .downloaded: "downloaded"
    case .unavailable(.needsWiFi): "unavailable(needsWiFi)"
    case .unavailable(.failed): "unavailable(failed)"
    case .unavailable(.timedOut): "unavailable(timedOut)"
    }
  }
}
