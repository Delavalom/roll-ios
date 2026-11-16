#if DEBUG
import CryptoKit
import Foundation
import Library
import Photos
import SwiftUI
import Synchronization
import UIKit
import UniformTypeIdentifiers
import Vision

// MARK: - Exporter

/// The export's file work. Shared state (counts for `done.json`, the thumbnail queue) sits behind a mutex; the vision
/// pass and the thumbnail loop run on their own detached tasks.
final class QAFindExporter: Sendable {
  struct AssetSummary: Sendable {
    let ids: [String]
    let assets: Int
    let withLocation: Int
    let albums: Int
  }

  struct Counts: Sendable {
    var assets = 0, withLocation = 0, albums = 0
    var visionDone = 0, visionMissing = 0, visionTotal = 0, visionFinished = false
    var thumbsDone = 0, thumbsOk = 0
    var assetsFinished = false
  }

  private let counts = Mutex(Counts())
  /// Thumbnail ids waiting to be written: the vision pass waits while this is above zero.
  private let pendingThumbs = Mutex(0)
  private let library = PhotoLibrary()

  private var fm: FileManager { .default }
  private var root: URL { QAFindExport.root }

  func prepare() throws {
    try fm.createDirectory(at: QAFindExport.thumbsDir, withIntermediateDirectories: true)
  }

  // MARK: Assets and albums

  /// Reads every image and video (hidden excluded, like Roll's own fetch) and the user albums, then writes
  /// `albums.json` and `assets.jsonl`. Nil if a file couldn't be written.
  func exportAssets() -> AssetSummary? {
    // Albums: regular and synced user albums, at any folder depth.
    var albums: [(key: String, title: String, count: Int)] = []
    var membership: [String: [String]] = [:]
    let memberOptions = PHFetchOptions()
    memberOptions.predicate = NSPredicate(
      format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
    collections.enumerateObjects { collection, _, _ in
      guard collection.assetCollectionSubtype == .albumRegular || collection.assetCollectionSubtype == .albumSyncedAlbum
      else { return }
      let key = "al" + Self.sha1Hex(collection.localIdentifier).prefix(10)
      var count = 0
      autoreleasepool {
        PHAsset.fetchAssets(in: collection, options: memberOptions).enumerateObjects { asset, _, _ in
          membership[asset.localIdentifier, default: []].append(key)
          count += 1
        }
      }
      albums.append((key, collection.localizedTitle ?? "", count))
    }
    let albumObjects: [[String: Any]] = albums.map { ["key": $0.key, "title": $0.title, "count": $0.count] }
    guard let albumData = try? JSONSerialization.data(withJSONObject: albumObjects,
                                                      options: [.prettyPrinted, .withoutEscapingSlashes]),
          (try? albumData.write(to: root.appending(path: "albums.json"), options: .atomic)) != nil
    else { return nil }

    // Assets, newest first.
    let options = PHFetchOptions()
    options.predicate = memberOptions.predicate
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let result = PHAsset.fetchAssets(with: options)
    let tmp = root.appending(path: "assets.jsonl.tmp")
    try? fm.removeItem(at: tmp)
    guard fm.createFile(atPath: tmp.path, contents: nil), let handle = try? FileHandle(forWritingTo: tmp) else { return nil }
    var ids: [String] = []
    ids.reserveCapacity(result.count)
    var withLocation = 0
    let page = 500
    for start in stride(from: 0, to: result.count, by: page) {
      autoreleasepool {
        var chunk = Data()
        result.enumerateObjects(at: IndexSet(integersIn: start..<min(start + page, result.count)), options: []) { asset, _, _ in
          let id = asset.localIdentifier
          ids.append(id)
          var lat: Any = NSNull(), lon: Any = NSNull(), hacc: Any = NSNull()
          if let location = asset.location, CLLocationCoordinate2DIsValid(location.coordinate) {
            lat = location.coordinate.latitude
            lon = location.coordinate.longitude
            hacc = location.horizontalAccuracy
            withLocation += 1
          }
          let line: [String: Any] = [
            "id": id,
            "created": asset.creationDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "lat": lat, "lon": lon, "hacc": hacc,
            "mediaType": asset.mediaType.rawValue, "subtypes": asset.mediaSubtypes.rawValue,
            "albums": membership[id] ?? [],
          ]
          if let data = try? JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]) {
            chunk.append(data)
            chunk.append(0x0A)
          }
        }
        try? handle.write(contentsOf: chunk)
      }
    }
    try? handle.close()
    let final = root.appending(path: "assets.jsonl")
    try? fm.removeItem(at: final)
    guard (try? fm.moveItem(at: tmp, to: final)) != nil else { return nil }

    counts.withLock {
      $0.assets = ids.count; $0.withLocation = withLocation; $0.albums = albums.count; $0.assetsFinished = true
      $0.visionTotal = ids.count
    }
    writeDone()
    return AssetSummary(ids: ids, assets: ids.count, withLocation: withLocation, albums: albums.count)
  }

  // MARK: Vision

  /// Classifies every id not yet in `vision.jsonl`, newest first, in small batches. Pauses while the iPhone is hot
  /// (thermal `.serious` or worse) and while thumbnails are waiting.
  func runVision(ids: [String], status: @Sendable (String) async -> Void) async {
    let url = root.appending(path: "vision.jsonl")
    let (seen, missingSeen) = Self.readVisionDone(url)
    let todo = ids.filter { !seen.contains($0) }
    var done = ids.count - todo.count, missing = missingSeen
    counts.withLock { $0.visionDone = done; $0.visionMissing = missing; $0.visionTotal = ids.count }
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: url) else {
      await status("vision: can't open vision.jsonl")
      return
    }
    _ = try? handle.seekToEnd()
    let start = ContinuousClock.now
    var doneThisRun = 0

    for batchStart in stride(from: 0, to: todo.count, by: QAFindExport.visionBatch) {
      // Thumbnails first.
      while pendingThumbs.withLock({ $0 }) > 0 { try? await Task.sleep(for: .milliseconds(250)) }
      // Cool down.
      var thermal = ProcessInfo.processInfo.thermalState
      while thermal == .serious || thermal == .critical {
        writeProgress(done: done, total: ids.count, missing: missing, phase: "thermalPause", rate: nil)
        await status("vision: paused (hot) \(done)/\(ids.count)")
        try? await Task.sleep(for: .seconds(15))
        thermal = ProcessInfo.processInfo.thermalState
      }
      var chunk = Data()
      for id in todo[batchStart..<min(batchStart + QAFindExport.visionBatch, todo.count)] {
        let result = await library.image(id: id, side: QAFindExport.visionSide, spec: .localBest)
        var line: [String: Any] = ["id": id]
        if let image = result.image {
          line["labels"] = Self.classify(image)
        } else {
          line["missing"] = true
          missing += 1
        }
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]) {
          chunk.append(data)
          chunk.append(0x0A)
        }
        done += 1
        doneThisRun += 1
      }
      try? handle.write(contentsOf: chunk)
      let minutes = Self.seconds(ContinuousClock.now - start) / 60
      let rate = minutes > 0 ? Double(doneThisRun) / minutes : 0
      counts.withLock { $0.visionDone = done; $0.visionMissing = missing }
      writeProgress(done: done, total: ids.count, missing: missing, phase: "vision", rate: rate)
      await status("vision: \(done)/\(ids.count), \(missing) missing, \(Int(rate))/min")
      try? await Task.sleep(for: .milliseconds(100))
    }
    try? handle.close()
    counts.withLock { $0.visionDone = done; $0.visionMissing = missing; $0.visionFinished = true }
    let minutes = Self.seconds(ContinuousClock.now - start) / 60
    writeProgress(done: done, total: ids.count, missing: missing, phase: "finished",
                  rate: minutes > 0 ? Double(doneThisRun) / minutes : 0)
    writeDone()
    await status("vision: finished \(done)/\(ids.count), \(missing) missing")
  }

  /// Ids already written (any line with an id) and how many of them were missing. A torn last line (the app was killed
  /// mid-write) is cut off so appends start on a fresh line.
  private static func readVisionDone(_ url: URL) -> (Set<String>, Int) {
    guard var data = try? Data(contentsOf: url), !data.isEmpty else { return ([], 0) }
    if data.last != 0x0A {
      let keep = (data.lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
      data = data.prefix(keep)
      if let h = try? FileHandle(forWritingTo: url) {
        try? h.truncate(atOffset: UInt64(keep))
        try? h.close()
      }
    }
    var seen = Set<String>(), missing = 0
    for line in data.split(separator: 0x0A) {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let id = object["id"] as? String else { continue }
      if seen.insert(id).inserted, object["missing"] as? Bool == true { missing += 1 }
    }
    return (seen, missing)
  }

  /// `VNClassifyImageRequest` labels with confidence >= 0.1, best first, at most 10, as `[identifier, confidence]`.
  private static func classify(_ image: CGImage) -> [[Any]] {
    autoreleasepool {
      let request = VNClassifyImageRequest()
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
      return observations
        .filter { $0.confidence >= QAFindExport.minConfidence }
        .sorted { $0.confidence > $1.confidence }
        .prefix(QAFindExport.maxLabels)
        .map { [$0.identifier, (Double($0.confidence) * 10_000).rounded() / 10_000] }
    }
  }

  // MARK: Thumbnails

  /// Every 5 s: reads `thumb-request.txt` and writes the thumbnails not yet in `thumbs/index.jsonl`.
  func serveThumbnails(status: @Sendable (Int, Int) async -> Void) async {
    let requestURL = root.appending(path: "thumb-request.txt")
    let indexURL = QAFindExport.thumbsDir.appending(path: "index.jsonl")
    var done = Set<String>(), ok = 0
    if let text = try? String(contentsOf: indexURL, encoding: .utf8) {
      for line in text.split(separator: "\n") {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = object["id"] as? String, done.insert(id).inserted else { continue }
        if object["ok"] as? Bool == true { ok += 1 }
      }
    }
    counts.withLock { $0.thumbsDone = done.count; $0.thumbsOk = ok }
    await status(done.count, ok)
    if !fm.fileExists(atPath: indexURL.path) { fm.createFile(atPath: indexURL.path, contents: nil) }

    while !Task.isCancelled {
      let requested = ((try? String(contentsOf: requestURL, encoding: .utf8)) ?? "")
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      var queue: [String] = []
      var queued = Set<String>()
      for id in requested where !done.contains(id) && queued.insert(id).inserted { queue.append(id) }
      if !queue.isEmpty, let handle = try? FileHandle(forWritingTo: indexURL) {
        _ = try? handle.seekToEnd()
        pendingThumbs.withLock { $0 = queue.count }
        for id in queue {
          let file = Self.sha1Hex(id).prefix(16) + ".jpg"
          let result = await library.image(id: id, side: QAFindExport.thumbSide, spec: .localBest)
          var written = false
          if let image = result.image, let jpeg = Self.jpeg(image, longest: QAFindExport.thumbSide, quality: 0.75) {
            written = (try? jpeg.write(to: QAFindExport.thumbsDir.appending(path: String(file)), options: .atomic)) != nil
          }
          let line: [String: Any] = ["id": id, "file": String(file), "ok": written]
          if var data = try? JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]) {
            data.append(0x0A)
            try? handle.write(contentsOf: data)
          }
          done.insert(id)
          if written { ok += 1 }
          pendingThumbs.withLock { $0 = max(0, $0 - 1) }
        }
        try? handle.close()
        pendingThumbs.withLock { $0 = 0 }
        counts.withLock { $0.thumbsDone = done.count; $0.thumbsOk = ok }
        writeDone()
        await status(done.count, ok)
      }
      try? await Task.sleep(for: .seconds(5))
    }
  }

  /// JPEG of `image` scaled down so its longest side is at most `longest` pixels.
  private static func jpeg(_ image: CGImage, longest: Int, quality: Double) -> Data? {
    let w = image.width, h = image.height
    let scale = min(1, Double(longest) / Double(max(w, h)))
    var output = image
    if scale < 1 {
      let tw = max(1, Int((Double(w) * scale).rounded())), th = max(1, Int((Double(h) * scale).rounded()))
      guard let context = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
      guard let scaled = context.makeImage() else { return nil }
      output = scaled
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  // MARK: Progress files

  private func writeProgress(done: Int, total: Int, missing: Int, phase: String, rate: Double?) {
    let object: [String: Any] = [
      "done": done, "total": total, "missing": missing, "phase": phase,
      "thermal": Self.thermalName(ProcessInfo.processInfo.thermalState),
      "itemsPerMinute": rate.map { ($0 * 10).rounded() / 10 as Any } ?? NSNull(),
      "updated": Date().timeIntervalSince1970,
    ]
    write(object, to: "progress.json")
  }

  private func writeDone() {
    let c = counts.withLock { $0 }
    write([
      "assets": c.assets, "withLocation": c.withLocation, "albums": c.albums, "assetsFinished": c.assetsFinished,
      "visionDone": c.visionDone, "visionMissing": c.visionMissing, "visionTotal": c.visionTotal,
      "visionFinished": c.visionFinished, "thumbsDone": c.thumbsDone, "thumbsOk": c.thumbsOk,
      "updated": Date().timeIntervalSince1970,
    ], to: "done.json")
  }

  private func write(_ object: [String: Any], to name: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else { return }
    try? data.write(to: root.appending(path: name), options: .atomic)
  }

  // MARK: Helpers

  static func sha1Hex(_ string: String) -> String {
    Insecure.SHA1.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
  }

  private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
#endif
