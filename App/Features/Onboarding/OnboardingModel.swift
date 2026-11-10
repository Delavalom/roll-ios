import Foundation
import Monitor
import Observation
import Overview
import Ranking
import Store

/// Onboarding (spec §10): one intro page, Photos permission, the taste scan, then the paywall. The aha is the taste
/// scan's number, so only one page stands before the permission ask; the swipes are taught where they're used
/// (`SwipeHint`).
@Observable @MainActor
final class OnboardingModel {
  enum Step: Equatable {
    case intro
    case permission
    case tasteScan
    case paywall
  }

  private(set) var step: Step = .intro
  private(set) var isRequesting = false
  let scan: TasteScanModel

  @ObservationIgnored private let app: AppModel

  init(app: AppModel) {
    self.app = app
    scan = TasteScanModel(app: app)
  }

  var access: AccessState { app.access }

  func next() {
    switch step {
    case .intro: step = .permission
    case .permission: break
    case .tasteScan: app.skipsPaywall ? finish() : (step = .paywall)
    case .paywall: finish()
    }
  }

  /// Asks for Photos access; on success the model download and the taste scan start.
  func requestAccess() async {
    isRequesting = true
    defer { isRequesting = false }
    await app.requestAccess()
    guard app.access.canRead else { return }
    step = .tasteScan
    scan.start()
  }

  /// The paywall's opening line: the number the taste scan just showed, or nil for the generic header.
  var paywallPitch: PaywallPitch? { scan.pitch }

  /// Without Photos access there is nothing to scan; Home explains how to turn it on.
  func continueWithoutAccess() { finish() }

  func finish() { app.completeOnboarding() }
}

/// Indexes the newest 500 assets with a live counter, then shows what Roll found (spec §10 step 3).
@Observable @MainActor
final class TasteScanModel {
  enum Phase: Equatable {
    case idle
    case scanning
    case done
    case failed
  }

  private(set) var phase: Phase = .idle
  private(set) var summary = CleanupSummary()
  /// Up to 6 ids from the Screenshots swipefile.
  private(set) var screenshotPreview: [String] = []
  /// The device's storage, read with the results.
  private(set) var storage: StorageSnapshot?

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var task: Task<Void, Never>?

  init(app: AppModel) { self.app = app }

  /// Live counter: assets looked at so far, of the scan's total.
  var processed: Int { app.indexProgress.phase == .indexing ? app.indexProgress.processed : 0 }
  var total: Int { app.indexProgress.phase == .indexing ? app.indexProgress.total : 0 }

  var modelState: AppModel.ModelState { app.modelState }

  /// The categories shown on the results screen, with what each frees on this iPhone (big videos at their squish
  /// savings, like the header). Categories with nothing on the device are left out (never "about 0 MB").
  var found: [FoundItem] { summary.foundOnDevice }

  /// The same total as Home's header: on this iPhone only, capped at the space in use. The storage is read once with
  /// the results, so the paywall that follows repeats exactly this number.
  var foundBytes: Int64 {
    summary.onDeviceHeadline(deviceTotal: storage?.total, deviceAvailable: storage?.available)
  }

  /// The paywall's opening line, from `foundBytes` and `found` (nil below `PaywallPitch.minimumBytes`).
  var pitch: PaywallPitch? { PaywallPitch.make(onDeviceBytes: foundBytes, found: found) }

  /// Originals stored in iCloud (freeing them frees iCloud space, not the iPhone's).
  var inCloudBytes: Int64 { summary.freeableInCloud }

  func start() {
    guard task == nil else { return }
    phase = .scanning
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.app.runTasteScan()
        try await self.loadResults()
        self.phase = .done
      } catch {
        try? await self.loadResults()
        self.phase = .failed
      }
    }
  }

  private func loadResults() async throws {
    summary = try await CleanupScanner(repositories: app.repositories).scan()
    storage = try? StorageStats.snapshot()
    screenshotPreview = try await app.previewCards(for: .screenshots, limit: 6)
  }
}
