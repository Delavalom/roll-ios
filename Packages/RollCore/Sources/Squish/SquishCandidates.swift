import Foundation
import Store

/// Which assets are worth offering for compression (spec §8).
public enum SquishCandidates {
  // PHAssetMediaSubtype raw values. Kept as plain ints so this module doesn't need Photos;
  // SquishCandidatesTests asserts them against the SDK.
  public static let photoDepthEffect = 1 << 4
  public static let photoLive = 1 << 3
  public static let photoAnimation = 1 << 6
  public static let spatialMedia = 1 << 10
  public static let videoHighFrameRate = 1 << 17
  public static let videoCinematic = 1 << 21
  /// Extra parts (Live motion, depth maps, spatial views, slo-mo ramps, animation frames) would be lost on
  /// re-encode, so v1 skips these.
  public static let excludedSubtypes = photoLive | photoDepthEffect | photoAnimation | spatialMedia
    | videoHighFrameRate | videoCinematic

  // PHAssetMediaType raw values.
  public static let imageMediaType = 1
  public static let videoMediaType = 2

  /// Sizes are decimal megabytes, matching how the UI says "about N MB".
  public static let minVideoBytes: Int64 = 50_000_000
  public static let minPhotoBytes: Int64 = 3_000_000
  /// A video qualifies on bitrate when it runs above this multiple of the HEVC target.
  public static let bitrateFactor = 1.5

  /// HEVC needs roughly this many bits per pixel per frame for visually transparent results.
  public static let hevcBitsPerPixel = 0.07
  /// What re-encoding a video that's already HEVC, at its own size, is expected to need: the export competes with the
  /// encoder that made the file (Apple's camera HEVC runs about 0.09 to 0.13 bits per pixel at 1080p and up), so it
  /// can't count on reaching `hevcBitsPerPixel`. An HEVC source is offered at its own size only above about
  /// 0.143 (this over 1 - `SquishPlanner.minimumSavingsFraction`): 8.9 Mbps at 1080p30. Downscales use the normal rate.
  public static let hevcReencodeBitsPerPixel = 0.10
  /// Bounds on the derived target, in bits per second.
  public static let minTargetBitrate = 1_500_000.0
  public static let maxTargetBitrate = 25_000_000.0
  /// `AssetRecord` doesn't carry a frame rate; assume this when the caller doesn't know it.
  public static let assumedFPS = 30.0

  /// The bitrate (bits per second) a typical HEVC encode needs: resolution x frame rate x bits per pixel,
  /// clamped to `minTargetBitrate...maxTargetBitrate`. An unknown size is treated as 1080p.
  public static func hevcTargetBitrate(pixelW: Int?, pixelH: Int?, fps: Double = assumedFPS,
                                       bitsPerPixel: Double = hevcBitsPerPixel) -> Double {
    let pixels: Double
    if let w = pixelW, let h = pixelH, w > 0, h > 0 { pixels = Double(w * h) } else { pixels = 1920 * 1080 }
    return min(maxTargetBitrate, max(minTargetBitrate, pixels * max(fps, 1) * bitsPerPixel))
  }

  /// What an encode is expected to produce: the target, but never more than the source already uses.
  public static func plannedOutputBitrate(pixelW: Int?, pixelH: Int?, fps: Double = assumedFPS,
                                          bitsPerPixel: Double = hevcBitsPerPixel, sourceBitrate: Double) -> Double {
    min(hevcTargetBitrate(pixelW: pixelW, pixelH: pixelH, fps: fps, bitsPerPixel: bitsPerPixel), sourceBitrate)
  }

  /// The size a plan counts for `record`: what the probe measured (`facts`), else the Store's estimate.
  public static func sourceBytes(_ record: AssetRecord, facts: VideoProbeFacts?) -> Int64 {
    facts?.bytes.flatMap { $0 > 0 ? $0 : nil } ?? record.estBytes
  }

  /// The frame rate a plan counts for a video: the probe's (`facts`), else `assumedFPS`.
  public static func frameRate(_ facts: VideoProbeFacts?) -> Double {
    facts?.fps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? assumedFPS
  }

  /// `isCandidate(_:)` with what the probe measured about a video (its real size and frame rate) when known. The
  /// bitrate is compared with the target at the 1080p cap (`Downscale`): a real 4K file runs below 1.5x the 4K
  /// target, yet downscaling it saves most of it. `SquishPlanner.offer` then applies the savings floor.
  public static func isCandidate(_ record: AssetRecord, facts: VideoProbeFacts?) -> Bool {
    guard let facts, record.mediaType == videoMediaType else { return isCandidate(record) }
    if record.deleted || record.burstId != nil || record.subtypes & excludedSubtypes != 0 { return false }
    let bytes = sourceBytes(record, facts: facts)
    if bytes > minVideoBytes { return true }
    guard let seconds = record.duration, seconds > 0, bytes > 0 else { return false }
    let capped = Downscale.forSource(w: record.pixelW ?? 0, h: record.pixelH ?? 0, keep4K: false)
    return Double(bytes) * 8 / seconds > bitrateFactor
      * hevcTargetBitrate(pixelW: capped?.toW ?? record.pixelW, pixelH: capped?.toH ?? record.pixelH, fps: frameRate(facts))
  }

  public static func isCandidate(_ record: AssetRecord) -> Bool {
    if record.deleted || record.burstId != nil || record.subtypes & excludedSubtypes != 0 { return false }
    switch record.mediaType {
    case imageMediaType:
      guard let uti = record.uti, uti == "public.jpeg" || uti == "public.png" else { return false }
      return record.estBytes > minPhotoBytes
    case videoMediaType:
      if record.estBytes > minVideoBytes { return true }
      guard let seconds = record.duration, seconds > 0, record.estBytes > 0 else { return false }
      let bitrate = Double(record.estBytes) * 8 / seconds
      return bitrate > bitrateFactor * hevcTargetBitrate(pixelW: record.pixelW, pixelH: record.pixelH)
    default:
      return false
    }
  }
}
