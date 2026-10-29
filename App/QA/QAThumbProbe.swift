#if DEBUG
import Foundation
import Photos
import Signals
import UIKit

/// DEBUG-only (`-QAThumbProbe`): with network access off, which thumbnail requests does the library answer locally,
/// and how long do Roll's Vision signals take per image on this phone? Read-only; counts and timings only.
enum QAThumbProbe {
  struct Config: Sendable {
    let name: String
    let side: Int
    let mode: PHImageRequestOptionsDeliveryMode
  }

  static let configs = [
    Config(name: "960-highQuality (indexer)", side: 960, mode: .highQualityFormat),
    Config(name: "900-highQuality (swipe card)", side: 900, mode: .highQualityFormat),
    Config(name: "512-highQuality", side: 512, mode: .highQualityFormat),
    Config(name: "300-highQuality (grid)", side: 300, mode: .highQualityFormat),
    Config(name: "960-fastFormat", side: 960, mode: .fastFormat),
    Config(name: "960-opportunistic", side: 960, mode: .opportunistic),
  ]

  static func run(sample: Int, log: QAEventLog) async {
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    options.fetchLimit = sample
    var assets: [PHAsset] = []
    PHAsset.fetchAssets(with: options).enumerateObjects { a, _, _ in assets.append(a) }
    // Spread across the library too: every Nth image of the whole set.
    let all = PHAsset.fetchAssets(with: .image, options: nil)
    let stride = max(1, all.count / sample)
    var spread: [PHAsset] = []
    for i in Swift.stride(from: 0, to: all.count, by: stride) where spread.count < sample { spread.append(all.object(at: i)) }

    for (setName, set) in [("newest", assets), ("spread", spread)] {
      for config in configs {
        var local = 0, degradedOnly = 0, inCloud = 0, failed = 0, sides: [Int] = []
        let start = ContinuousClock.now
        for asset in set {
          let r = await request(asset, config)
          if let side = r.finalSide { local += 1; sides.append(side) }
          else if let side = r.degradedSide { degradedOnly += 1; sides.append(side) }
          else if r.inCloud { inCloud += 1 }
          else { failed += 1 }
        }
        let s = seconds(ContinuousClock.now - start)
        sides.sort()
        log.write("thumb_probe", [
          "set": .string(setName), "config": .string(config.name), "n": .int(set.count), "local": .int(local),
          "degradedOnly": .int(degradedOnly), "inCloud": .int(inCloud), "failed": .int(failed),
          "medianLongSide": .int(sides.isEmpty ? 0 : sides[sides.count / 2]), "seconds": .double(s),
        ])
      }
    }

    // Vision signal cost per image, on the locally available 960 px thumbnails of the newest images (or the
    // largest local image the library offers).
    let extractor = SignalExtractor()
    var times: [Double] = []
    var smallest = Int.max
    for asset in assets.prefix(120) {
      var r = await request(asset, configs[0])
      if r.image == nil { r = await request(asset, configs[5]) }
      guard let image = r.image else { continue }
      smallest = min(smallest, max(image.width, image.height))
      let t0 = ContinuousClock.now
      _ = try? await extractor.extract(image)
      times.append(seconds(ContinuousClock.now - t0) * 1000)
    }
    times.sort()
    log.write("signal_timing", [
      "images": .int(times.count),
      "medianMs": .double(times.isEmpty ? 0 : times[times.count / 2]),
      "p90Ms": .double(times.isEmpty ? 0 : times[Int(Double(times.count - 1) * 0.9)]),
      "meanMs": .double(times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)),
      "smallestLongSide": .int(smallest == .max ? 0 : smallest),
      "thermal": .int(ProcessInfo.processInfo.thermalState.rawValue),
    ])
  }

  struct Result: @unchecked Sendable {
    var image: CGImage?
    var finalSide: Int?
    var degradedSide: Int?
    var inCloud = false
  }

  private final class Box: @unchecked Sendable {
    var result = Result()
    var resumed = false
  }

  static func request(_ asset: PHAsset, _ config: Config) async -> Result {
    let options = PHImageRequestOptions()
    options.deliveryMode = config.mode
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    options.isSynchronous = false
    let box = Box()
    let lock = NSLock()
    return await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
      PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: config.side, height: config.side),
                                            contentMode: .aspectFit, options: options) { image, info in
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
        let cloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
        let side = image.map { Int(max($0.size.width * $0.scale, $0.size.height * $0.scale)) }
        lock.lock()
        defer { lock.unlock() }
        guard !box.resumed else { return }
        if degraded {
          box.result.degradedSide = side
          if box.result.image == nil { box.result.image = image?.cgImage }
          if config.mode == .fastFormat { box.resumed = true; c.resume(returning: box.result) }
          return  // a final callback follows
        }
        box.result.finalSide = side
        if let cg = image?.cgImage { box.result.image = cg }
        box.result.inCloud = cloud
        box.resumed = true
        c.resume(returning: box.result)
      }
    }
  }

  static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}
#endif
