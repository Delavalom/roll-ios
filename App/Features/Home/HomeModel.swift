import Foundation
import Monitor
import Observation
import Overview
import Store

/// Home's numbers: the cleanup summary, recomputed when the library changes (an index batch landed, a sync or a
/// commit finished; `AppModel.bumpLibrary`). Scans run one at a time and at most once per `minimumInterval`; changes
/// that arrive meanwhile fold into the next scan. The totals read the slim rows; duplicate groups (every feature
/// print) are rebuilt only when indexing isn't running, or every `regroupInterval` while it is, and reused between.
@Observable @MainActor
final class HomeModel {
  static let minimumInterval: Duration = .seconds(5)
  static let regroupInterval: Duration = .seconds(45)

  private(set) var summary = CleanupSummary()
  private(set) var hasLoaded = false
  /// The device's storage, read with each scan: Home never shows more than the space in use.
  private(set) var storage: StorageSnapshot?

  @ObservationIgnored private let scanner: CleanupScanner
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var dirty = false
  @ObservationIgnored private var lastScan: ContinuousClock.Instant?
  @ObservationIgnored private var groups: [[String]]?
  @ObservationIgnored private var lastGrouping: ContinuousClock.Instant?
  @ObservationIgnored private var indexing = false

  init(repositories: Repositories) {
    scanner = CleanupScanner(repositories: repositories)
  }

  /// - Parameter indexing: whether the Indexer is still working (groups are then rebuilt at most every
  ///   `regroupInterval`; the change that ends a run always regroups).
  func libraryChanged(indexing: Bool = false) {
    self.indexing = indexing
    dirty = true
    guard task == nil else { return }
    task = Task { [weak self] in
      while let self, self.dirty {
        self.dirty = false
        if let last = self.lastScan {
          let wait = Self.minimumInterval - (ContinuousClock.now - last)
          if wait > .zero { try? await Task.sleep(for: wait) }
        }
        let scanner = self.scanner
        let regroup = self.groups == nil || !self.indexing
          || self.lastGrouping.map { ContinuousClock.now - $0 >= Self.regroupInterval } ?? true
        if regroup, let fresh = try? await scanner.groups() {
          self.groups = fresh
          self.lastGrouping = .now
        }
        if let groups = self.groups, let fresh = try? await scanner.scan(groups: groups) {
          self.summary = fresh
          self.storage = try? StorageStats.snapshot()
          self.hasLoaded = true
        }
        self.lastScan = .now
      }
      self?.task = nil
    }
  }

  /// "You can free about X on this iPhone": only originals on the device, capped at the space in use.
  var headlineBytes: Int64 {
    summary.onDeviceHeadline(deviceTotal: storage?.total, deviceAvailable: storage?.available)
  }

  /// The paywall's opening line when it's reached from the app (the free cleanups ran out, say): Home's own headline
  /// and categories, so it never shows a number Home doesn't. nil until Home has loaded, or below the floor.
  var paywallPitch: PaywallPitch? { PaywallPitch.make(onDeviceBytes: headlineBytes, found: summary.foundOnDevice) }

  /// One card per category, in Home's order.
  var cards: [HomeCard] {
    [
      HomeCard(kind: .duplicates, total: summary[.duplicates], unit: ("extra copy", "extra copies")),
      HomeCard(kind: .similarShots, total: summary[.similarShots], unit: ("extra shot", "extra shots")),
      HomeCard(kind: .screenshots, total: summary[.screenshots], unit: ("screenshot", "screenshots")),
      HomeCard(kind: .blurry, total: summary[.blurry], unit: ("blurry photo", "blurry photos")),
      HomeCard(kind: .bigVideos, total: summary[.bigVideos], unit: ("big video", "big videos"),
               squishSavings: summary.bigVideoSavingsOnDevice),
    ]
  }
}

struct HomeCard: Identifiable {
  let kind: CleanupCategory
  let total: CategoryTotal
  let unit: (one: String, many: String)
  /// Big videos only: about how much squishing them saves (the card's size stays their full size).
  var squishSavings: Int64 = 0

  var id: CleanupCategory { kind }

  var countText: String { "\(total.count.formatted()) \(total.count == 1 ? unit.one : unit.many)" }

  var symbol: String {
    switch kind {
    case .duplicates: "square.on.square"
    case .similarShots: "square.stack.3d.down.right"
    case .screenshots: "iphone"
    case .blurry: "camera.metering.unknown"
    case .bigVideos: "film.stack"
    }
  }

  /// Big videos are squished, not deleted: say so, with what that saves on this iPhone (Home's header counts it).
  var detail: String? {
    guard kind == .bigVideos else { return nil }
    return squishSavings > 0 ? "Squish to save \(ByteFormat.about(squishSavings))" : "Squish them to a smaller size"
  }

  /// The card's size: what's on this iPhone ("about 1.2 GB"), "in iCloud" when none of it is, nothing at zero. Big
  /// videos say "in iCloud or not checked yet", as Home's headline does: their originals are checked in the background
  /// after indexing, and an unchecked one counts as iCloud.
  var bytesText: String? {
    if total.onDeviceBytes > 0 { return ByteFormat.about(total.onDeviceBytes) }
    guard total.inCloudBytes > 0 else { return nil }
    return kind == .bigVideos ? "in iCloud or not checked yet" : "in iCloud"
  }
}
