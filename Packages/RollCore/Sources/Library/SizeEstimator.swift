import Foundation

/// Rough on-disk size of an asset. PhotoKit has no public file-size API and Roll does not read
/// `PHAssetResource` via KVC (ADR-0001), so the UI always says "about".
///
/// Photos: pixels × bytes-per-pixel by container (an untyped photo too small for a type lookup uses the rate of the
/// small saved images it usually is). Videos: duration × a bitrate table keyed by the
/// short side (so portrait clips match) and frame rate. All arithmetic is integer except the
/// duration product, which rounds to the nearest byte.
public enum SizeEstimator {
  /// Bits per second for a video of this size and frame rate.
  public static func videoBitrate(pixelW: Int, pixelH: Int, fps: Double) -> Int64 {
    let shortSide = min(pixelW, pixelH)
    switch shortSide {
    case 2160...: return 45_000_000
    case 1080...: return fps >= 50 ? 18_000_000 : 10_000_000
    case 720...: return 5_000_000
    default: return 2_500_000
    }
  }

  /// Hundredths of a byte per pixel for a screenshot (flat UI, usually PNG): the largest of 16 real 1284×2778 PNG
  /// captures from an iPhone 13 Pro Max in device QA (median 0.12, max 0.40 B/px). The photographic PNG rate (1.6)
  /// overstated 2,523 screenshots as 11.2 GB. Re-check with real files (`-QASizeProbe`) when a device is free.
  static let screenshotCentibytesPerPixel: Int64 = 40

  /// Squish's photo minimum (`SquishCandidates.minPhotoBytes`), mirrored here because Library doesn't depend on
  /// Squish; `TypeLookupFloorTests` keeps the two equal.
  public static let squishPhotoMinimumBytes: Int64 = 3_000_000

  /// Photos below this can't be Squish candidates whatever their type: 3 MB at PNG's 1.6 B/px, the densest type Squish
  /// takes, is 1.875 MP. Their type is never looked up (`Indexer.resolveTypes`); from here up it is, largest first.
  public static let typeLookupMinimumPixels = Int(squishPhotoMinimumBytes * 100 / centibytesPerPixel(uti: "public.png"))

  /// Hundredths of a byte per pixel for a photo below `typeLookupMinimumPixels` whose type was never looked up. Under
  /// 1.9 MP a photo is rarely a camera HEIC (iPhone cameras shoot 12 MP and up); it's mostly an image saved from a
  /// messaging app or the web, nearly always JPEG, re-encoded at lower quality than the camera's. 0.6 is two thirds of
  /// the JPEG rate: it errs low against it (the HEIC rate, 0.35, put these photos at 0.39x the JPEG rate, about 2.5x
  /// under) while the occasional small HEIC is over by 1.7x at most.
  static let smallUntypedCentibytesPerPixel: Int64 = 60

  /// Hundredths of a byte per pixel for a photo container, from its UTI.
  /// HEIC/HEIF and an unknown UTI (the iPhone default) 0.35, PNG 1.6, JPEG and anything else 0.9.
  static func centibytesPerPixel(uti: String?) -> Int64 {
    guard let uti = uti?.lowercased(), !uti.isEmpty else { return 35 }  // "": looked up, none reported
    switch uti {
    case "public.heic", "public.heif": return 35
    case "public.png": return 160
    default: return 90
    }
  }

  public static func estimate(mediaType: Int, pixelW: Int, pixelH: Int, duration: Double, uti: String?,
                              fps: Double = 30, isScreenshot: Bool = false) -> Int64 {
    switch mediaType {
    case MediaKind.image:
      let pixels = Int64(max(0, pixelW)) * Int64(max(0, pixelH))
      var rate = centibytesPerPixel(uti: uti)
      if uti == nil, pixels < Int64(typeLookupMinimumPixels) { rate = smallUntypedCentibytesPerPixel }
      if isScreenshot { rate = min(rate, screenshotCentibytesPerPixel) }
      return pixels * rate / 100
    case MediaKind.video:
      guard duration.isFinite, duration > 0 else { return 0 }
      let bitsPerSecond = videoBitrate(pixelW: pixelW, pixelH: pixelH, fps: fps)
      return Int64((duration * Double(bitsPerSecond) / 8).rounded())
    default:
      return 0
    }
  }

  /// PhotoKit does not report a frame rate, so it is derived from the subtypes: a
  /// `videoHighFrameRate` clip (60/120/240 fps) uses the 60 fps bitrate tier, anything else 30.
  public static func frameRate(of snapshot: AssetSnapshot) -> Double {
    snapshot.has(MediaSubtype.videoHighFrameRate) ? 60 : 30
  }

  public static func estimate(_ snapshot: AssetSnapshot) -> Int64 {
    estimate(mediaType: snapshot.mediaType, pixelW: snapshot.pixelW, pixelH: snapshot.pixelH,
             duration: snapshot.duration, uti: snapshot.uti, fps: frameRate(of: snapshot),
             isScreenshot: snapshot.has(MediaSubtype.screenshot))
  }
}
