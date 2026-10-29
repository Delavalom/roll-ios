#if DEBUG
import Darwin
import Foundation
import Indexer
import ModelInstall
import Monitor
import Overview
import Photos
import SquishBridge
import Store
import UIKit

/// DEBUG-only device QA metrics (`-QAMetrics` or `-QAAlbum`), written to `Documents/qa/metrics.jsonl` through
/// `QAEventLog`. Counts, sizes, timings and states only: never asset identifiers or photo content.
///
/// - `session`: hardware, iOS version, physical memory, the QA mode;
/// - `library_totals`: PhotoKit counts by type (read-only fetches) and the Store's view (`store_stats`, every 30 s);
/// - `index_run` / `index_batch`: per 200-asset batch: count, ms, items/s and how many thumbnails were iCloud-only or
///   failed; per run: processed, total, seconds;
/// - `mem`: `phys_footprint` once a second with the peak and `os_proc_available_memory`;
/// - `thermal`, `battery`: on every change (battery level also every 60 s);
/// - `home`: the Home summary (each category's count and bytes, freeable bytes, duplicate group stats) on change;
/// - `model`: the on-device model's state on change;
/// - `monitor`: what the Monitor screen reads (storage, RAM), every 60 s, plus other capacity keys to compare.
@MainActor
final class QAMetrics {
  private let runtime: QARuntime
  private let app: AppModel
  private var log: QAEventLog { runtime.log }
  private var tasks: [Task<Void, Never>] = []
  private var observers: [NSObjectProtocol] = []
  private var peakFootprint: UInt64 = 0
  private var lastHome: CleanupSummary?
  private var lastModel: String?

  init(runtime: QARuntime, app: AppModel) {
    self.runtime = runtime
    self.app = app
  }

  func start() {
    session()
    observeThermalAndBattery()
    observeIndexer()
    tasks.append(Task { [weak self] in
      var tick = 0
      while !Task.isCancelled {
        guard let self else { return }
        self.sampleMemory()
        if tick % 2 == 0 { self.checkHomeAndModel() }
        if tick % 30 == 0 { await self.storeStats() }
        if tick % 60 == 0 { self.battery(reason: "periodic"); self.monitor() }
        if tick == 5 { await self.libraryTotals() }
        tick += 1
        try? await Task.sleep(for: .seconds(1))
      }
    })
  }

  // MARK: Session

  private func session() {
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let device = UIDevice.current
    log.write("session", [
      "machine": .string(machine), "model": .string(device.model), "system": .string(device.systemName),
      "osVersion": .string(device.systemVersion), "physicalMemory": .int(Int64(ProcessInfo.processInfo.physicalMemory)),
      "cores": .int(ProcessInfo.processInfo.activeProcessorCount),
      "mode": .string(runtime.isReadOnly ? "read-only" : "qa-album"),
      "lowPowerMode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
      "photosAccess": .string("\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)"),
    ])
  }

  // MARK: Memory

  static func footprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : nil
  }

  private func sampleMemory() {
    guard let now = Self.footprint() else { return }
    peakFootprint = max(peakFootprint, now)
    let available = os_proc_available_memory()
    log.write("mem", [
      "footprintMB": .double(Self.mb(now)), "peakMB": .double(Self.mb(peakFootprint)),
      "availableMB": .double(Self.mb(UInt64(available))),
      // The jetsam limit is roughly what's in use plus what's still available to this process.
      "limitMB": .double(Self.mb(now + UInt64(available))),
      "phase": .string(Self.phase(app.indexProgress.phase)), "processed": .int(app.indexProgress.processed),
    ])
  }

  static func mb(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

  // MARK: Thermal and battery

  private func observeThermalAndBattery() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    thermal(reason: "start")
    battery(reason: "start")
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.thermal(reason: "change") }
    })
    for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.battery(reason: "change") }
      })
    }
  }

  private func thermal(reason: String) {
    let state = switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
    log.write("thermal", ["state": .string(state), "reason": .string(reason)])
  }

  private func battery(reason: String) {
    let device = UIDevice.current
    let state = switch device.batteryState {
    case .charging: "charging"
    case .full: "full"
    case .unplugged: "unplugged"
    default: "unknown"
    }
    log.write("battery", ["level": .double(Double(device.batteryLevel)), "state": .string(state), "reason": .string(reason)])
  }

  // MARK: Indexer

  private func observeIndexer() {
    let indexer = app.indexer, log = log, counters = runtime.counters
    tasks.append(Task {
      var runStart = ContinuousClock.now, batchStart = ContinuousClock.now
      var runCounts = counters.current, batchCounts = counters.current
      var lastBatchEnd = 0, runId = -1, total = 0, lastProcessed = 0
      func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
      for await progress in await indexer.progressUpdates() {
        if progress.runId != runId, progress.phase == .started || progress.phase == .indexing {
          runId = progress.runId
          runStart = .now; batchStart = .now; lastBatchEnd = 0
          runCounts = counters.current; batchCounts = runCounts
          log.write("index_run", ["state": .string("started"), "total": .int(progress.total)])
        }
        total = max(total, progress.total)
        switch progress.phase {
        case .indexing:
          lastProcessed = progress.processed
          if progress.processed - lastBatchEnd >= 200 {
            let now = ContinuousClock.now, c = counters.current, delta = c - batchCounts
            let count = progress.processed - lastBatchEnd, s = seconds(now - batchStart)
            log.write("index_batch", [
              "count": .int(count), "ms": .int(Int64(s * 1000)), "itemsPerSecond": .double(s > 0 ? Double(count) / s : 0),
              "processed": .int(progress.processed), "total": .int(progress.total),
              "thumbs": .int(delta.total), "inCloud": .int(delta.inCloud), "failed": .int(delta.failed),
              "previews": .int(delta.preview),
              "cloudShare": .double(delta.total > 0 ? Double(delta.inCloud) / Double(delta.total) : 0),
              "analysedShare": .double(delta.total > 0 ? Double(delta.image + delta.preview) / Double(delta.total) : 0),
              "failedShare": .double(delta.total > 0 ? Double(delta.failed) / Double(delta.total) : 0),
              "thermal": .int(ProcessInfo.processInfo.thermalState.rawValue),
            ])
            lastBatchEnd = progress.processed; batchStart = now; batchCounts = c
          }
        case .thermalPause:
          log.write("index_run", ["state": .string("thermalPause"), "processed": .int(progress.processed)])
        case .finished, .cancelled, .failed:
          let s = seconds(ContinuousClock.now - runStart), delta = counters.current - runCounts
          log.write("index_run", [
            "state": .string(Self.phase(progress.phase)), "processed": .int(max(progress.processed, lastProcessed)),
            "total": .int(total), "seconds": .double(s),
            "itemsPerSecond": .double(s > 0 ? Double(max(progress.processed, lastProcessed)) / s : 0),
            "thumbs": .int(delta.total), "inCloud": .int(delta.inCloud), "failed": .int(delta.failed),
            "previews": .int(delta.preview), "full": .int(delta.image),
          ])
          runId = -1; total = 0; lastProcessed = 0
        default:
          break
        }
      }
    })
  }

  static func phase(_ phase: IndexProgress.Phase) -> String {
    switch phase {
    case .idle: "idle"
    case .syncing: "syncing"
    case .started: "started"
    case .indexing: "indexing"
    case .thermalPause: "thermalPause"
    case .finished: "finished"
    case .cancelled: "cancelled"
    case .failed: "failed"
    }
  }

  // MARK: Library, Store, Home, model, Monitor

  /// PhotoKit counts for the whole library (read-only fetches; counts only).
  private func libraryTotals() async {
    func count(_ type: PHAssetMediaType?, subtype: PHAssetMediaSubtype? = nil, favorite: Bool = false,
               hidden: Bool = false) -> Int {
      let options = PHFetchOptions()
      var predicates: [NSPredicate] = []
      if let type { predicates.append(NSPredicate(format: "mediaType == %d", type.rawValue)) }
      if let subtype { predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue)) }
      if favorite { predicates.append(NSPredicate(format: "favorite == YES")) }
      if hidden {
        options.includeHiddenAssets = true
        predicates.append(NSPredicate(format: "hidden == YES"))
      }
      if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
      return type.map { PHAsset.fetchAssets(with: $0, options: options).count } ?? PHAsset.fetchAssets(with: options).count
    }
    log.write("library_totals", [
      "all": .int(count(nil)), "images": .int(count(.image)), "videos": .int(count(.video)), "audio": .int(count(.audio)),
      "screenshots": .int(count(.image, subtype: .photoScreenshot)), "livePhotos": .int(count(.image, subtype: .photoLive)),
      "hdrPhotos": .int(count(.image, subtype: .photoHDR)), "portrait": .int(count(.image, subtype: .photoDepthEffect)),
      "panoramas": .int(count(.image, subtype: .photoPanorama)),
      "slomo": .int(count(.video, subtype: .videoHighFrameRate)), "timelapse": .int(count(.video, subtype: .videoTimelapse)),
      "screenRecordings": .int(count(.video, subtype: .videoScreenRecording)),
      "cinematic": .int(count(.video, subtype: .videoCinematic)), "favorites": .int(count(nil, favorite: true)),
      "hidden": .int(count(nil, hidden: true)),
      "userAlbums": .int(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).count),
    ])
  }

  private func storeStats() async {
    guard let stats = try? await app.repositories.qaStats() else { return }
    log.write("store_stats", payload: stats)
  }

  private func checkHomeAndModel() {
    let model = switch app.modelState {
    case .ready: "ready"
    case .unavailable(let issue): "not ready (\(issue))"
    case .waiting(let reason, _): "waiting (\(reason))"
    case .loading(let p): p.map { "loading \($0.completedBytes)/\($0.totalBytes)" } ?? "loading"
    case .preparing(let done, let total): "preparing \(done)/\(total)"
    }
    if model != lastModel {
      lastModel = model
      log.write("model", ["state": .string(model)])
    }
    let summary = app.home.summary
    guard app.home.hasLoaded, summary != lastHome else { return }
    lastHome = summary
    var fields: [String: QAEventLog.Value] = [
      "freeableBytes": .int(summary.freeableBytes), "bigVideoSavings": .int(summary.bigVideoSavings),
      "freeableOnDevice": .int(summary.freeableOnDevice), "freeableInCloud": .int(summary.freeableInCloud),
      "bigVideoSavingsOnDevice": .int(summary.bigVideoSavingsOnDevice), "headlineBytes": .int(app.home.headlineBytes),
      "libraryOnDeviceBytes": .int(summary.library.onDeviceBytes), "libraryInCloudBytes": .int(summary.library.inCloudBytes),
      "libraryCount": .int(summary.library.count), "libraryBytes": .int(summary.library.bytes),
      "queuedCount": .int(summary.queued.count), "queuedBytes": .int(summary.queued.bytes),
      "swipefiles": .int(summary.swipefileCount), "indexPhase": .string(Self.phase(app.indexProgress.phase)),
    ]
    for category in CleanupCategory.allCases {
      fields["\(category.rawValue)Count"] = .int(summary[category].count)
      fields["\(category.rawValue)Bytes"] = .int(summary[category].bytes)
    }
    for (name, kind) in [("dup", DuplicateGroup.Kind.duplicates), ("similar", .similarShots)] {
      let groups = summary.groups(kind)
      let sizes = groups.map(\.members.count)
      fields["\(name)Groups"] = .int(groups.count)
      fields["\(name)Members"] = .int(sizes.reduce(0, +))
      fields["\(name)Largest"] = .int(sizes.max() ?? 0)
      fields["\(name)ReclaimableBytes"] = .int(groups.reduce(0) { $0 + $1.reclaimableBytes })
    }
    log.write("home", fields)
    let repositories = app.repositories, log = log
    Task {
      guard let catalog = try? await SquishCatalog.load(repositories: repositories, keep4K: false) else { return }
      let selected = Set(catalog.defaultSelection)
      log.write("squish_catalog", [
        "items": .int(catalog.items.count), "cloudOnly": .int(catalog.cloudOnly.count),
        "defaultSelection": .int(selected.count), "hdrKept": .int(catalog.hdrKept.count),
        "notSquishable": .int(catalog.notSquishable.count),
        "selectedSavings": .int(catalog.items.filter { selected.contains($0.assetID) }.reduce(0) { $0 + $1.estimatedSavings }),
        "allSavings": .int(catalog.items.reduce(0) { $0 + $1.estimatedSavings }),
      ])
    }
  }

  /// What the Monitor shows (storage via `StorageStats`, RAM via `HostStats`), plus the other capacity keys, so the
  /// report can compare with Settings > General > iPhone Storage.
  private func monitor() {
    var fields: [String: QAEventLog.Value] = [:]
    if let s = try? StorageStats.snapshot() {
      fields["storageTotal"] = .int(s.total); fields["storageAvailableImportant"] = .int(s.available)
    }
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForOpportunisticUsageKey]
    if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys) {
      if let a = v.volumeAvailableCapacity { fields["storageAvailable"] = .int(a) }
      if let o = v.volumeAvailableCapacityForOpportunisticUsage { fields["storageAvailableOpportunistic"] = .int(o) }
    }
    if let m = HostStats.memory() {
      fields["ramUsed"] = .int(Int64(m.used)); fields["ramTotal"] = .int(Int64(m.total))
      fields["ramFree"] = .int(Int64(m.free)); fields["ramWired"] = .int(Int64(m.wired))
      fields["ramCompressed"] = .int(Int64(m.compressed))
    }
    fields["uptime"] = .double(ProcessInfo.processInfo.systemUptime)
    log.write("monitor", fields)
  }
}
#endif
