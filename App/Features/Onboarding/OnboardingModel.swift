import Foundation
import Monitor
import Observation
import Overview
import Ranking
import Store

/// Onboarding (spec §10): three value pages, Photos permission, the taste scan, then the paywall.
@Observable @MainActor
final class OnboardingModel {
  enum Step: Equatable {
    case value(Int)
    case permission
    case tasteScan
    case paywall
  }

  static let valuePages = 3

  private(set) var step: Step = .value(0)
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
    case .value(let page): step = page + 1 < Self.valuePages ? .value(page + 1) : .permission
    case .permission: break
    case .tasteScan: app.skipsPaywall ? finish() : (step = .paywall)
    case .paywall: finish()
    }
  }

  func showPage(_ page: Int) { step = .value(page) }

  /// Asks for Photos access; on success the model download and the taste scan start.
  func requestAccess() async {
    isRequesting = true
    defer { isRequesting = false }
    await app.requestAccess()
    guard app.access.canRead else { return }
    step = .tasteScan
    scan.start()
  }

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

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var task: Task<Void, Never>?

  init(app: AppModel) { self.app = app }

  /// Live counter: assets looked at so far, of the scan's total.
  var processed: Int { app.indexProgress.phase == .indexing ? app.indexProgress.processed : 0 }
  var total: Int { app.indexProgress.phase == .indexing ? app.indexProgress.total : 0 }

  var modelState: AppModel.ModelState { app.modelState }

  /// The categories shown on the results screen, with what each frees on this iPhone (big videos at their squish
  /// savings, like the header). Categories with nothing on the device are left out (never "about 0 MB").
  var found: [(title: String, bytes: Int64)] {
    let rows: [(String, Int64)] = [
      ("Screenshots", summary[.screenshots].onDeviceBytes),
      ("Duplicates and similar shots", summary[.duplicates].onDeviceBytes + summary[.similarShots].onDeviceBytes),
      ("Squishing big videos", summary.bigVideoSavingsOnDevice),
      ("Blurry", summary[.blurry].onDeviceBytes),
    ]
    return rows.filter { $0.1 > 0 }.map { (title: $0.0, bytes: $0.1) }
  }

  /// The same total as Home's header: on this iPhone only, capped at the space in use.
  var foundBytes: Int64 {
    let storage = try? StorageStats.snapshot()
    return summary.onDeviceHeadline(deviceTotal: storage?.total, deviceAvailable: storage?.available)
  }

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
    screenshotPreview = try await app.previewCards(for: .screenshots, limit: 6)
  }
}
