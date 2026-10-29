#if DEBUG
import AVFoundation
import Commit
import Foundation
import Photos
import Squish
import Synchronization

/// DEBUG-only: the QA album's contents by type, format, size and duration, with what Squish would decide up front.
/// Read-only: resources are streamed with network access off (an iCloud-only original is reported, not downloaded).
/// No identifiers, file names, dates or locations are recorded, only whether metadata exists.
struct QAInventoryItem: Codable, Sendable {
  var index = 0
  var kind = ""
  var subtypes: [String] = []
  var resources: [String] = []
  var uti: String?
  var pixelWidth = 0
  var pixelHeight = 0
  var durationSeconds: Double = 0
  /// Bytes of the main resource, read locally; nil when it is only in iCloud.
  var bytes: Int64?
  var localOriginal = false
  var favorite = false
  var hidden = false
  var hasLocation = false
  var hasCreationDate = false
  var edited = false
  var burst = false
  var userLibrary = false
  var userAlbums = 0
  /// `SquishEligibility` on the flow's own facts; nil when the up-front checks pass.
  var squishRefusedUpFront: String?
  var video: QAVideoFormat?
  var photo: QAPhotoFormat?
}

struct QAInventory: Codable, Sendable {
  var sequence = 0
  var albumFound = false
  var count = 0
  var items: [QAInventoryItem] = []
  var byKindAndFormat: [String: Int] = [:]
}

enum QAInventoryRunner {
  static func directory() -> URL { QAEventLog.directory }

  /// Writes `Documents/qa/album-inventory-<sequence>.json` and a summary line to the metrics log.
  static func run(title: String, sequence: Int, log: QAEventLog) async -> QAInventory {
    var inventory = QAInventory(sequence: sequence)
    guard let album = album(title) else {
      write(inventory, log: log)
      return inventory
    }
    inventory.albumFound = true
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    var assets: [PHAsset] = []
    PHAsset.fetchAssets(in: album, options: options).enumerateObjects { a, _, _ in assets.append(a) }
    inventory.count = assets.count
    for (i, asset) in assets.enumerated() {
      var item = await describe(asset)
      item.index = i
      inventory.items.append(item)
      let format = item.video.map { v in "\(v.codec)\(v.refusedAs.map { "/\($0)" } ?? "")\(v.transferFunction.map { "/\($0)" } ?? "")" }
        ?? item.uti ?? "?"
      inventory.byKindAndFormat["\(item.kind) \(format)", default: 0] += 1
    }
    write(inventory, log: log)
    return inventory
  }

  private static func album(_ title: String) -> PHAssetCollection? {
    var match: PHAssetCollection?
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, stop in
      if c.localizedTitle == title { match = c; stop.pointee = true }
    }
    return match
  }

  private static func write(_ inventory: QAInventory, log: QAEventLog) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(inventory) {
      try? data.write(to: directory().appending(path: "album-inventory-\(inventory.sequence).json"))
    }
    log.write("album_inventory", [
      "sequence": .int(inventory.sequence), "found": .bool(inventory.albumFound), "count": .int(inventory.count),
      "formats": .string(inventory.byKindAndFormat.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        .joined(separator: ", ")),
    ])
  }

  private static func describe(_ asset: PHAsset) async -> QAInventoryItem {
    var item = QAInventoryItem()
    item.kind = asset.mediaType == .video ? "video" : asset.mediaType == .image ? "photo" : "other"
    item.subtypes = subtypeNames(asset.mediaSubtypes)
    item.pixelWidth = asset.pixelWidth; item.pixelHeight = asset.pixelHeight
    item.durationSeconds = asset.duration
    item.favorite = asset.isFavorite; item.hidden = asset.isHidden
    item.hasLocation = asset.location != nil; item.hasCreationDate = asset.creationDate != nil
    item.burst = asset.burstIdentifier != nil
    item.userLibrary = asset.sourceType == .typeUserLibrary
    PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { c, _, _ in
      if c.assetCollectionSubtype == .albumRegular { item.userAlbums += 1 }
    }
    let resources = PHAssetResource.assetResources(for: asset)
    item.resources = resources.map { "\($0.type.rawValue)" }
    item.edited = resources.contains { [.adjustmentData, .fullSizePhoto, .fullSizeVideo].contains($0.type) }
    let main = resources.first { $0.type == .photo || $0.type == .video }
    item.uti = main?.uniformTypeIdentifier
    if let eligibility = await ReplaceFlow.qaEligibility(assetID: asset.localIdentifier) {
      item.squishRefusedUpFront = eligibility.refusedAs
    }
    guard let main else { return item }
    if asset.mediaType == .video {
      if let avAsset = await localAVAsset(asset) {
        item.localOriginal = true
        item.video = await QAMediaProbe.video(avAsset)
        if let url = (avAsset as? AVURLAsset)?.url,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { item.bytes = Int64(size) }
      }
      if item.bytes == nil, let data = await localData(main, keep: false) {
        item.bytes = data.bytes; item.localOriginal = true
      }
    } else if let data = await localData(main, keep: true) {
      item.localOriginal = true
      item.bytes = data.bytes
      item.photo = data.data.map(QAMediaProbe.photo)
    }
    return item
  }

  static func subtypeNames(_ s: PHAssetMediaSubtype) -> [String] {
    let names: [(PHAssetMediaSubtype, String)] = [
      (.photoPanorama, "panorama"), (.photoHDR, "hdr"), (.photoScreenshot, "screenshot"), (.photoLive, "live"),
      (.photoDepthEffect, "depth"), (.videoStreamed, "streamed"), (.videoHighFrameRate, "slomo"),
      (.videoTimelapse, "timelapse"), (.videoScreenRecording, "screenRecording"), (.videoCinematic, "cinematic"),
      (.spatialMedia, "spatial"),
    ]
    var out = names.filter { s.contains($0.0) }.map(\.1)
    if s.rawValue & (1 << 6) != 0 { out.append("animation") }
    return out
  }

  /// The original video, local only (network off). nil when it is only in iCloud.
  static func localAVAsset(_ asset: PHAsset) async -> AVAsset? {
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = false
    options.version = .original
    options.deliveryMode = .highQualityFormat
    return await withCheckedContinuation { (c: CheckedContinuation<AVAsset?, Never>) in
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
        nonisolated(unsafe) let result = avAsset
        c.resume(returning: result)
      }
    }
  }

  struct LocalData: Sendable { var bytes: Int64; var data: Data? }

  /// Streams a resource with network access off. Keeps the bytes when `keep` (photos, for the format probe).
  private static func localData(_ resource: PHAssetResource, keep: Bool) async -> LocalData? {
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = false
    let buffer = Mutex<(Int64, Data)>((0, Data()))
    return await withCheckedContinuation { (c: CheckedContinuation<LocalData?, Never>) in
      PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
        buffer.withLock {
          $0.0 += Int64(chunk.count)
          if keep { $0.1.append(chunk) }
        }
      }, completionHandler: { error in
        let (bytes, data) = buffer.withLock { $0 }
        c.resume(returning: error == nil ? LocalData(bytes: bytes, data: keep ? data : nil) : nil)
      })
    }
  }

  // MARK: Dolby Vision experiment (temp files only)

  /// For each Dolby Vision clip in the album (at most 3), exports it with each HEVC preset into the temporary
  /// directory, records what the output keeps, and deletes the output. Never writes to the photo library.
  static func dolbyVisionExperiment(title: String, log: QAEventLog) async {
    guard let album = album(title) else { return }
    var videos: [PHAsset] = []
    PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in if a.mediaType == .video { videos.append(a) } }
    let directory = FileManager.default.temporaryDirectory.appending(path: "qa-dv", directoryHint: .isDirectory)
    var done = 0
    for (i, video) in videos.enumerated() where done < 3 {
      guard let avAsset = await localAVAsset(video) else {
        log.write("dv_experiment_skip", ["videoIndex": .int(i), "reason": .string("original only in iCloud")])
        continue
      }
      let format = await QAMediaProbe.video(avAsset)
      guard format.refusedAs == "dolbyVision" else { continue }
      done += 1
      for preset in QADolbyVisionExperiment.presets {
        let result = await QADolbyVisionExperiment.run(avAsset, preset: preset, directory: directory)
        log.write("dv_experiment", payload: result)
      }
    }
    try? FileManager.default.removeItem(at: directory)
    log.write("dv_experiment_done", ["clips": .int(done), "videosInAlbum": .int(videos.count)])
  }
}
#endif
