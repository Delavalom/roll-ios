#if DEBUG
import Dedupe
import Foundation
import Library
import Memories
import Photos
import Signals
import Store

/// DEBUG-only (`-QAMemoryReel <album title>`): build a memory video from that user album and write
/// `Documents/qa/reel/reel.mp4` and `metrics.json` (counts, seconds and megabytes only, no identifiers). Read-only on
/// the library. Aesthetics, screenshot/document flag and look-alike groups come from the same Vision signals and
/// `DuplicateGrouper` / `KeeperPolicy` the app uses, computed on the fly from 512 px thumbnails.
enum QAMemoryReel {
  static let directory = URL.documentsDirectory.appending(path: "qa/reel", directoryHint: .isDirectory)

  static func title(in arguments: [String]) -> String? {
    guard let i = arguments.firstIndex(of: "-QAMemoryReel"), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    return value.hasPrefix("-") || value.isEmpty ? nil : value
  }

  static func run(title: String, seconds: Double, log: QAEventLog) async {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    while ![.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) {
      try? await Task.sleep(for: .seconds(1))
    }
    var metrics: [String: Any] = ["album": "user-album", "targetSeconds": seconds]
    defer { write(metrics) }
    let assets = albumAssets(title: title)
    metrics["albumItems"] = assets.count
    guard !assets.isEmpty else { metrics["error"] = "album missing or empty"; return }

    let t0 = ContinuousClock.now
    let records = await analyse(assets)
    let candidates = candidates(from: records, assets: assets)
    metrics["analysisSeconds"] = secs(ContinuousClock.now - t0)
    metrics["similarGroups"] = Set(candidates.compactMap(\.similarGroup)).count
    metrics["screenshotsOrDocuments"] = candidates.filter(\.isScreenshotOrDocument).count

    let plan = MemoryReelPlanner.plan(candidates: candidates, target: ReelTarget(seconds: seconds))
    metrics["shots"] = plan.shots.count
    metrics["videoShots"] = plan.shots.filter { $0.kind == .video }.count
    metrics["plannedSeconds"] = plan.duration
    if let problem = plan.problem { metrics["error"] = problem.message; return }

    let wifi = await WiFi.isAvailable()
    let exporter = MemoryVideoExporter(source: PhotoKitReelSource(wifi: wifi))
    do {
      let result = try await exporter.export(plan, to: directory.appending(path: "reel.mp4")) { p in
        if Int(p * 100) % 25 == 0 { log.write("memory_reel_progress", ["percent": .int(Int(p * 100))]) }
      }
      metrics["codec"] = result.codec
      metrics["frames"] = result.frames
      metrics["skippedShots"] = result.skippedShots
      metrics["renderSeconds"] = result.renderSeconds
      metrics["fileMB"] = Double(result.fileBytes) / 1_048_576
      metrics["peakFootprintMB"] = Double(result.peakFootprintBytes) / 1_048_576
      metrics["totalSeconds"] = secs(ContinuousClock.now - t0)
    } catch { metrics["error"] = String(describing: error) }
    log.write("memory_reel_done", ["shots": .int(plan.shots.count), "failed": .bool(metrics["error"] != nil)])
  }

  // MARK: - Inputs

  private static func albumAssets(title: String) -> [PHAsset] {
    let wholeLibrary = title == "*"  // simulator seeding can't make albums; "*" reads every photo and video, still read-only
    let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
    var match: PHAssetCollection?
    albums.enumerateObjects { c, _, stop in if c.localizedTitle == title { match = c; stop.pointee = true } }
    guard let match = match ?? nil, !wholeLibrary else {
      guard wholeLibrary else { return [] }
      var all: [PHAsset] = []
      PHAsset.fetchAssets(with: nil).enumerateObjects { a, _, _ in
        if a.mediaType == .image || a.mediaType == .video { all.append(a) }
      }
      return all
    }
    var out: [PHAsset] = []
    PHAsset.fetchAssets(in: match, options: nil).enumerateObjects { a, _, _ in
      if a.mediaType == .image || a.mediaType == .video { out.append(a) }
    }
    return out
  }

  /// Roll's own signals on a 512 px thumbnail of each item, as the `AssetRecord`s the dedupe code takes.
  private static func analyse(_ assets: [PHAsset]) async -> [AssetRecord] {
    let library = PhotoLibrary()
    let extractor = SignalExtractor()
    var records: [AssetRecord] = []
    for asset in assets {
      let id = asset.localIdentifier
      let result = asset.mediaType == .video ? await library.videoFrame(id: id, side: 512) : await library.thumbnail(id: id, side: 512)
      var record = AssetRecord(id: id, mediaType: asset.mediaType == .video ? 2 : 1, subtypes: Int(asset.mediaSubtypes.rawValue),
                               created: asset.creationDate?.timeIntervalSince1970, pixelW: asset.pixelWidth, pixelH: asset.pixelHeight,
                               duration: asset.duration, isFavorite: asset.isFavorite)
      if let image = result.image, let s = try? await extractor.extract(image) {
        record.aesthetic = s.aesthetic.map(Double.init)
        record.isUtility = s.isUtility
        record.phash = s.phash
        record.featurePrint = s.featurePrint
        record.previewSide = max(image.width, image.height)
        record.signalsDone = true
      }
      records.append(record)
    }
    return records
  }

  private static func candidates(from records: [AssetRecord], assets: [PHAsset]) -> [ReelCandidate] {
    let groups = DuplicateGrouper.groups(records: records, prepare: { FeaturePrints.decode($0) }, distance: { $0.distance(to: $1) })
    var label: [String: String] = [:], keeper: [String: String] = [:]
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    for (n, ids) in groups.enumerated() {
      let pick = KeeperPolicy.keeper(ids.compactMap { byID[$0] })
      for id in ids { label[id] = "g\(n)"; keeper[id] = pick }
    }
    return records.map { r in
      let screenshot = r.subtypes & (1 << 2) != 0
      return ReelCandidate(id: r.id, created: Date(timeIntervalSince1970: r.created ?? 0), isVideo: r.mediaType == 2,
                           duration: r.duration ?? 0, aesthetic: r.aesthetic, isScreenshotOrDocument: screenshot || r.isUtility == true,
                           similarGroup: label[r.id], isKeeper: keeper[r.id] == r.id)
    }
  }

  private static func write(_ metrics: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: directory.appending(path: "metrics.json"))
  }

  private static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}
#endif
