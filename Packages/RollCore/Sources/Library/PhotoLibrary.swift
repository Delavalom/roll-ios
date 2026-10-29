#if canImport(Photos) && os(iOS)
import AVFoundation
import Photos
import UIKit

/// The one definition of "which assets Roll looks at", shared by enumeration and the change observer.
enum LibraryFetch {
  static func options(sorted: Bool) -> PHFetchOptions {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(
      format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
    if sorted { options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] }
    return options
  }
}

/// PhotoKit access for reads: authorization, enumeration, thumbnails and video frames.
/// Destructive calls never live here (see AGENTS.md). Not unit-tested: it needs a live photo library.
public struct PhotoLibrary: Sendable {
  public init() {}

  /// Current status without prompting.
  public func currentAuthorization() -> PHAuthorizationStatus {
    PHPhotoLibrary.authorizationStatus(for: .readWrite)
  }

  /// Requests read/write access (full library recommended; limited works on the selected set).
  public func authorization() async -> PHAuthorizationStatus {
    await PHPhotoLibrary.requestAuthorization(for: .readWrite)
  }

  /// Every image and video, newest first, **without UTIs**: every snapshot has `uti == nil`, because
  /// looking up resources for each asset is slow at 50k assets.
  ///
  /// Contract for the Indexer's `sync()`: for ids the Store already has, keep the stored UTI (the Store's
  /// `upsertAssets` does this: a nil `uti` never overwrites one). For ids new to the Store, call
  /// `utis(for:)` and merge the result into the snapshots **before** computing `estBytes` with
  /// `SizeEstimator`, since the byte estimate depends on the container.
  ///
  /// Runs in pages of `readBatch`, yielding between pages. At utility QoS it took 31.6 s on a 30k library (device
  /// re-run) without staying cool, so it runs at medium: the first screen waits for it. File types aren't read here at
  /// all (`utis(for:)` runs lazily for candidates).
  public func fetchAll() async -> [AssetSnapshot] {
    await Task.detached(priority: .medium) {
      let result = PHAsset.fetchAssets(with: LibraryFetch.options(sorted: true))
      var snapshots: [AssetSnapshot] = []
      snapshots.reserveCapacity(result.count)
      for start in stride(from: 0, to: result.count, by: Self.readBatch) {
        let range = start..<min(start + Self.readBatch, result.count)
        autoreleasepool {
          result.enumerateObjects(at: IndexSet(integersIn: range), options: []) { asset, _, _ in
            snapshots.append(AssetSnapshot(asset))
          }
        }
        await Task.yield()
      }
      return snapshots
    }.value
  }

  /// Assets read per page by `fetchAll()` and `utis(for:)`.
  static let readBatch = 500

  /// Snapshots for the given ids only (for incremental `LibraryChange`s), without UTIs, like `fetchAll()`.
  /// Ids that no longer resolve to an image or video are left out, so the caller can treat them as gone.
  public func snapshots(ids: [String]) -> [AssetSnapshot] {
    let wanted = Self.assets(ids: ids)
    return ids.compactMap { id in
      guard let asset = wanted[id], asset.mediaType == .image || asset.mediaType == .video else { return nil }
      return AssetSnapshot(asset)
    }
  }

  /// Uniform type identifiers of the original resources, for the given ids only. The original
  /// (`.photo` / `.video`) resource is preferred over adjustment or sidecar resources.
  ///
  /// The heaviest part of a first sync (one resource lookup per asset), so it runs at utility QoS in pages of
  /// `readBatch` ids, yielding between pages.
  public func utis(for ids: [String]) async -> [String: String] {
    guard !ids.isEmpty else { return [:] }
    return await Task.detached(priority: .utility) {
      var utis: [String: String] = [:]
      utis.reserveCapacity(ids.count)
      for start in stride(from: 0, to: ids.count, by: Self.readBatch) {
        let page = Array(ids[start..<min(start + Self.readBatch, ids.count)])
        autoreleasepool {
          PHAsset.fetchAssets(withLocalIdentifiers: page, options: nil).enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            if let uti = original?.uniformTypeIdentifier { utis[asset.localIdentifier] = uti }
          }
        }
        await Task.yield()
      }
      return utis
    }.value
  }

  /// One image request for swipe cards and full-screen views (`CardImageLoader` picks the specs; `.download` only on
  /// Wi-Fi). A missing asset is `.failed`, a cancelled task `.cancelled`.
  public func image(id: String, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult {
    guard let asset = Self.assets(ids: [id])[id] else { return .failed }
    return await Self.requestImage(for: asset, side: side, spec: spec)
  }

  /// A thumbnail whose longer side is about `side` pixels, upright. One result per requested id
  /// (missing assets are `.failed`, and a cancelled task gets `.cancelled`).
  public func thumbnail(id: String, side: Int, allowNetwork: Bool = false) async -> ThumbnailResult {
    await thumbnails(ids: [id], side: side, allowNetwork: allowNetwork)[id] ?? .failed
  }

  /// Thumbnails for a batch with a single `fetchAssets(withLocalIdentifiers:)`. Requests run one after
  /// another to keep memory flat; cancelling the task cancels the in-flight request and fails the rest.
  public func thumbnails(ids: [String], side: Int, allowNetwork: Bool = false) async -> [String: ThumbnailResult] {
    var results: [String: ThumbnailResult] = [:]
    let assets = Self.assets(ids: ids)
    for id in ids {
      if Task.isCancelled { results[id] = .cancelled; continue }
      guard let asset = assets[id] else { results[id] = .failed; continue }
      results[id] = await Self.requestImage(for: asset, side: side, spec: ImageRequestSpec(allowNetwork: allowNetwork, previews: true))
    }
    return results
  }

  /// One frame of a video at `fraction` (default 10%) of its duration, longer side at most `side`, upright.
  public func videoFrame(id: String, at fraction: Double = 0.1, side: Int = 960, allowNetwork: Bool = false) async -> ThumbnailResult {
    guard let asset = Self.assets(ids: [id])[id], asset.mediaType == .video else { return .failed }
    let loaded = await Self.requestAVAsset(for: asset, allowNetwork: allowNetwork)
    guard let avAsset = loaded.asset else {
      // An iCloud-only video still has a local poster preview: use it rather than skipping the video.
      guard case .inCloud = loaded.status else { return loaded.status }
      let poster = await Self.requestImage(for: asset, side: side, spec: .localBest)
      return poster.image.map(ThumbnailResult.preview) ?? loaded.status
    }
    let generator = AVAssetImageGenerator(asset: avAsset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: side, height: side)
    let seconds = max(0, asset.duration) * min(max(fraction, 0), 1)
    do {
      return .image(try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
    } catch is CancellationError {
      return .cancelled
    } catch {
      return Task.isCancelled ? .cancelled : .failed
    }
  }

  // MARK: requests

  private static func assets(ids: [String]) -> [String: PHAsset] {
    guard !ids.isEmpty else { return [:] }
    let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var assets: [String: PHAsset] = [:]
    assets.reserveCapacity(result.count)
    result.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
    return assets
  }

  /// What the PhotoKit handler delivered. The `UIImage` rides in an unchecked-Sendable box so the
  /// upright redraw (CPU work) happens after the `await`, on the caller's executor and never on the
  /// main thread that PhotoKit may call back on.
  private struct RawImage: @unchecked Sendable {
    var image: UIImage?
    var preview: UIImage?
    var isInCloud = false
    var hasError = false
    var cancelled = false
  }

  /// The degraded image an opportunistic request delivers first, kept until the final call decides.
  private final class PreviewBox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: UIImage?
    func set(_ new: UIImage?) { lock.withLock { if let new { image = new } } }
    var value: UIImage? { lock.withLock { image } }
  }

  /// `ImageRequestSpec` decides the options. An opportunistic request (network off) first delivers a degraded local
  /// preview, then the final image, or nothing (with `PHImageResultIsInCloudKey`) when the original is only in iCloud.
  /// The preview is then the result (`ThumbnailResult.preview`). A high-quality request delivers once.
  private static func requestImage(for asset: PHAsset, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult {
    let allowNetwork = spec.allowsNetwork
    let options = PHImageRequestOptions()
    options.deliveryMode = switch spec.delivery {
    case .opportunistic: .opportunistic
    case .highQuality: .highQualityFormat
    }
    options.resizeMode = .fast
    options.isSynchronous = false
    options.isNetworkAccessAllowed = allowNetwork
    let target = CGSize(width: side, height: side)
    let manager = PHImageManager.default()
    let shot = OneShot<RawImage>(cancelledValue: RawImage(cancelled: true))
    let preview = PreviewBox()
    let raw = await shot.run { shot in
      let requestID = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) {
        image, info in
        if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
          preview.set(image)
          return  // the final delivery follows
        }
        shot.resolve(RawImage(
          image: image, preview: preview.value, isInCloud: (info?[PHImageResultIsInCloudKey] as? Bool) == true,
          hasError: info?[PHImageErrorKey] != nil, cancelled: (info?[PHImageCancelledKey] as? Bool) == true))
      }
      shot.setCancelAction { manager.cancelImageRequest(requestID) }
    }
    let upright = raw.image.flatMap(UprightImage.cgImage(from:))
    let uprightPreview = raw.preview.flatMap(UprightImage.cgImage(from:))
    return ThumbnailResult.classify(
      image: upright, isInCloud: raw.isInCloud, hasError: raw.hasError, cancelled: raw.cancelled,
      allowNetwork: allowNetwork, preview: uprightPreview)
  }

  private struct LoadedAVAsset: @unchecked Sendable {
    var asset: AVAsset?
    var status: ThumbnailResult  // .failed, .inCloud or .cancelled when `asset` is nil
  }

  private static func requestAVAsset(for asset: PHAsset, allowNetwork: Bool) async -> LoadedAVAsset {
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = allowNetwork
    // .automatic, not .highQualityFormat: this is a single still. Verify on device with Optimize
    // Storage on, where an iCloud-only original must report inCloud instead of triggering a download.
    options.deliveryMode = .automatic
    let manager = PHImageManager.default()
    let shot = OneShot<LoadedAVAsset>(cancelledValue: LoadedAVAsset(asset: nil, status: .cancelled))
    return await shot.run { shot in
      let requestID = manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
        let status = ThumbnailResult.classify(
          image: nil, isInCloud: (info?[PHImageResultIsInCloudKey] as? Bool) == true,
          hasError: info?[PHImageErrorKey] != nil, cancelled: (info?[PHImageCancelledKey] as? Bool) == true,
          allowNetwork: allowNetwork)
        shot.resolve(LoadedAVAsset(asset: avAsset, status: status))
      }
      shot.setCancelAction { manager.cancelImageRequest(requestID) }
    }
  }
}

extension AssetSnapshot {
  /// Builds a snapshot from a PHAsset without touching its resources (`uti` stays nil; see `PhotoLibrary.utis(for:)`).
  public init(_ asset: PHAsset) {
    self.init(
      id: asset.localIdentifier, mediaType: asset.mediaType.rawValue, subtypes: Int(asset.mediaSubtypes.rawValue),
      created: asset.creationDate?.timeIntervalSince1970, pixelW: asset.pixelWidth, pixelH: asset.pixelHeight,
      duration: asset.duration, isFavorite: asset.isFavorite, burstId: asset.burstIdentifier, uti: nil,
      modified: asset.modificationDate?.timeIntervalSince1970)
  }
}
#endif
