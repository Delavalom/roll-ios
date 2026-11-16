import AVFoundation
import Library
import Memories
import Photos

/// Reads reel pictures from the photo library. Read-only. Photos come in at about 2200 px on the long side (the frame
/// is 1920 tall and the Ken Burns zoom needs the margin); the original is only downloaded from iCloud when `wifi` says
/// so, otherwise the local preview stands in. Video shots are decoded frame by frame with `AVAssetImageGenerator`.
actor PhotoKitReelSource: ReelFrameSource {
  static let photoSide = 2200

  private let library = PhotoLibrary()
  private let wifi: Bool
  private var photos: [String: ReelFrame] = [:]
  private var recent: [String] = []
  private var generators: [String: VideoFrames] = [:]

  /// - Parameter wifi: whether iCloud-only originals may be downloaded (`WiFi.isAvailable()`).
  init(wifi: Bool) { self.wifi = wifi }

  func prepare(_ shot: ReelShot) async {
    if shot.kind == .photo { _ = await photo(shot.id) } else { _ = await generator(shot.id) }
  }

  func frame(for shot: ReelShot, at localTime: Double) async -> ReelFrame? {
    switch shot.kind {
    case .photo: return await photo(shot.id)
    case .video:
      guard let generator = await generator(shot.id) else { return nil }
      let time = CMTime(seconds: shot.sourceStart + localTime, preferredTimescale: 600)
      guard let image = try? await generator.image(at: time) else { return nil }
      return .centred(image)
    }
  }

  private func photo(_ id: String) async -> ReelFrame? {
    if let cached = photos[id] { return cached }
    var result = await library.image(id: id, side: Self.photoSide, spec: .localSharp)
    if result.image == nil, wifi { result = await library.image(id: id, side: Self.photoSide, spec: .download) }
    if result.image == nil { result = await library.image(id: id, side: Self.photoSide, spec: .localBest) }
    guard let image = result.image else { return nil }
    let frame = ReelFrame(image: image, focus: FaceFocus.focus(in: image))
    photos[id] = frame
    recent.append(id)
    // Only the shot on screen and the one fading in need to stay in memory.
    while recent.count > 3 { photos[recent.removeFirst()] = nil }
    return frame
  }

  private func generator(_ id: String) async -> VideoFrames? {
    if let existing = generators[id] { return existing }
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
          let avAsset = await Self.avAsset(for: asset, network: wifi) else { return nil }
    let generator = VideoFrames(avAsset)
    generators[id] = generator
    if generators.count > 2, let old = generators.keys.first(where: { $0 != id }) { generators[old] = nil }
    return generator
  }

  private static func avAsset(for asset: PHAsset, network: Bool) async -> AVAsset? {
    await withCheckedContinuation { continuation in
      let options = PHVideoRequestOptions()
      options.isNetworkAccessAllowed = network
      options.deliveryMode = .highQualityFormat
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
        nonisolated(unsafe) let result = avAsset
        continuation.resume(returning: result)
      }
    }
  }
}

/// One clip's frame generator behind a `Sendable` face (the generator is only ever used through `image(at:)`).
final class VideoFrames: @unchecked Sendable {
  private let generator: AVAssetImageGenerator

  init(_ asset: AVAsset) {
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: 1920, height: 1920)
  }

  func image(at time: CMTime) async throws -> CGImage { try await generator.image(at: time).image }
}
