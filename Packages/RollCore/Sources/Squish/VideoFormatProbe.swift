import AVFoundation
import Foundation
import Store
#if canImport(Photos) && os(iOS)
import Library
import Photos
#endif

/// What a local video's track format says about squishing it, read before the user selects anything. The same check
/// as at export time (`VideoSquisher.unsupportedFormat`: Dolby Vision codecs `dvh1`/`dvhe`/`dvav`/`dva1` or their
/// configuration atoms, ProRes codecs, the Apple Log transfer function).
public enum VideoFormatVerdict: Sendable, Equatable {
  case squishable, dolbyVision, proRes, appleLog

  init(_ unsupported: VideoSquisher.UnsupportedFormat?) {
    switch unsupported {
    case nil: self = .squishable
    case .dolbyVision: self = .dolbyVision
    case .proRes: self = .proRes
    case .appleLog: self = .appleLog
    }
  }

  /// The verdict for every video track of `asset` (the first refusal wins).
  public static func of(_ asset: AVAsset) async throws -> VideoFormatVerdict {
    for track in try await asset.loadTracks(withMediaType: .video) {
      for desc in try await track.load(.formatDescriptions) {
        let verdict = VideoFormatVerdict(VideoSquisher.unsupportedFormat(desc))
        if verdict != .squishable { return verdict }
      }
    }
    return .squishable
  }
}

/// One probe's answer: the format verdict and, for a squishable video, what the file measured.
public struct VideoProbeResult: Sendable, Equatable {
  public var verdict: VideoFormatVerdict
  /// nil when nothing was measured (the planner then uses the Store's estimate).
  public var facts: VideoProbeFacts?
  public init(verdict: VideoFormatVerdict, facts: VideoProbeFacts? = nil) { self.verdict = verdict; self.facts = facts }
}

extension VideoProbeFacts {
  /// Measures a readable video: the first video track's codec and nominal frame rate, and the file's size (a file
  /// URL's size; otherwise the tracks' estimated data rates over the duration). Read-only.
  public static func measure(_ asset: AVAsset) async throws -> VideoProbeFacts {
    var facts = VideoProbeFacts()
    let tracks = try await asset.load(.tracks)
    if let video = try await asset.loadTracks(withMediaType: .video).first {
      let (descs, fps) = try await video.load(.formatDescriptions, .nominalFrameRate)
      facts.codec = descs.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
      facts.fps = fps > 0 ? Double(fps) : nil
    }
    if let url = (asset as? AVURLAsset)?.url, url.isFileURL,
       let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
      facts.bytes = Int64(size)
    } else {
      let seconds = try await asset.load(.duration).seconds
      var bitsPerSecond = 0.0
      for track in tracks { bitsPerSecond += Double(try await track.load(.estimatedDataRate)) }
      if seconds.isFinite, seconds > 0, bitsPerSecond > 0 { facts.bytes = Int64(bitsPerSecond * seconds / 8) }
    }
    return facts
  }

  static func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

/// Reads a video's format without downloading it.
public protocol VideoFormatProbing: Sendable {
  /// nil when the original isn't on this iPhone (or can't be read): nothing is known then.
  func verdict(for assetID: String) async -> VideoFormatVerdict?
  /// The verdict plus what the file measured (`VideoProbeFacts`). The default measures nothing.
  func probe(for assetID: String) async -> VideoProbeResult?
}

extension VideoFormatProbing {
  public func probe(for assetID: String) async -> VideoProbeResult? {
    await verdict(for: assetID).map { VideoProbeResult(verdict: $0) }
  }
}

#if canImport(Photos) && os(iOS)
/// `VideoFormatProbing` over PhotoKit: the original video, network access off. Read-only.
public struct PhotoKitVideoFormatProbe: VideoFormatProbing {
  public init() {}

  public func verdict(for assetID: String) async -> VideoFormatVerdict? {
    guard let avAsset = await original(of: assetID) else { return nil }
    return try? await VideoFormatVerdict.of(avAsset)
  }

  /// The verdict, then (for a squishable video) its codec, real file size and frame rate.
  public func probe(for assetID: String) async -> VideoProbeResult? {
    guard let avAsset = await original(of: assetID),
          let verdict = try? await VideoFormatVerdict.of(avAsset), !Task.isCancelled else { return nil }
    guard verdict == .squishable else { return VideoProbeResult(verdict: verdict) }
    return VideoProbeResult(verdict: verdict, facts: try? await VideoProbeFacts.measure(avAsset))
  }

  /// The local original as an `AVAsset`, or nil (not on this iPhone, not a video, or cancelled).
  private func original(of assetID: String) async -> AVAsset? {
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: options).firstObject,
          asset.mediaType == .video else { return nil }
    let request = PHVideoRequestOptions()
    request.isNetworkAccessAllowed = false
    request.version = .original
    request.deliveryMode = .highQualityFormat
    // Cancellable (`OneShot`): a caller that gives up (`SquishFormatScreen`'s timeout) cancels the request too.
    let manager = PHImageManager.default()
    let shot = OneShot<AssetBox>(cancelledValue: AssetBox(asset: nil))
    let box = await shot.run { shot in
      let requestID = manager.requestAVAsset(forVideo: asset, options: request) { avAsset, _, _ in
        shot.resolve(AssetBox(asset: avAsset))
      }
      shot.setCancelAction { manager.cancelImageRequest(requestID) }
    }
    guard let avAsset = box.asset, !Task.isCancelled else { return nil }
    return avAsset
  }

  private struct AssetBox: @unchecked Sendable { var asset: AVAsset? }
}
#endif
