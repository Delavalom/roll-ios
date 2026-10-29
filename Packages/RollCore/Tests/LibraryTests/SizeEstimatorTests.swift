import Testing
@testable import Library

struct SizeEstimatorTests {
  // 4000 × 3000 = 12_000_000 px
  @Test func heicIsPointThreeFiveBytesPerPixel() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 4000, pixelH: 3000, duration: 0, uti: "public.heic") == 4_200_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 4000, pixelH: 3000, duration: 0, uti: "public.heif") == 4_200_000)
  }

  @Test func jpegIsPointNineBytesPerPixel() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 4000, pixelH: 3000, duration: 0, uti: "public.jpeg") == 10_800_000)
  }

  @Test func pngIsOnePointSixBytesPerPixel() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1170, pixelH: 2532, duration: 0, uti: "public.png") == 4_739_904)
  }

  @Test func unknownUTIsFollowTheDocumentedFallbacks() {
    // nil at camera sizes = iPhone default (HEIC rate) until the type is looked up; another known-nothing format =
    // JPEG rate.
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 4000, pixelH: 3000, duration: 0, uti: nil) == 4_200_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1000, pixelH: 1000, duration: 0, uti: "com.compuserve.gif") == 900_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1000, pixelH: 1000, duration: 0, uti: "PUBLIC.PNG") == 1_600_000)
  }

  @Test func imagePixelMathIsIntegerFloor() {
    // 3 px × 0.35 = 1.05 -> 1
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 3, pixelH: 1, duration: 0, uti: "public.heic") == 1)
  }

  @Test func fourKVideoIs45Mbps() {
    // 10 s × 45 Mb/s / 8
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 3840, pixelH: 2160, duration: 10, uti: nil, fps: 30) == 56_250_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 3840, pixelH: 2160, duration: 10, uti: nil, fps: 60) == 56_250_000)
  }

  @Test func fullHDDependsOnFrameRate() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: 10, uti: nil, fps: 30) == 12_500_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: 10, uti: nil, fps: 60) == 22_500_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: 10, uti: nil, fps: 50) == 22_500_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: 10, uti: nil, fps: 49) == 12_500_000)
  }

  @Test func hdVideoIs5Mbps() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1280, pixelH: 720, duration: 8, uti: nil) == 5_000_000)
  }

  @Test func smallVideoIs2Point5Mbps() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 640, pixelH: 480, duration: 8, uti: nil) == 2_500_000)
  }

  @Test func portraitVideoUsesTheShortSide() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1080, pixelH: 1920, duration: 10, uti: nil, fps: 30) == 12_500_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 2160, pixelH: 3840, duration: 1, uti: nil, fps: 30) == 5_625_000)
  }

  @Test func tierBoundariesUseTheShortSide() {
    #expect(SizeEstimator.videoBitrate(pixelW: 3840, pixelH: 2159, fps: 30) == 10_000_000)
    #expect(SizeEstimator.videoBitrate(pixelW: 1920, pixelH: 1079, fps: 60) == 5_000_000)
    #expect(SizeEstimator.videoBitrate(pixelW: 1280, pixelH: 719, fps: 30) == 2_500_000)
  }

  @Test func videoDurationRoundsToTheNearestByte() {
    // 0.1 s × 2.5 Mb/s / 8 = 31_250 exactly; 0.3333 s -> 104_156.25 -> 104_156
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 320, pixelH: 240, duration: 0.1, uti: nil) == 31_250)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 320, pixelH: 240, duration: 0.3333, uti: nil) == 104_156)
  }

  @Test func degenerateInputsAreZero() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: 0, uti: nil) == 0)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: -3, uti: nil) == 0)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: .nan, uti: nil) == 0)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 0, pixelH: 3000, duration: 0, uti: "public.heic") == 0)
    #expect(SizeEstimator.estimate(mediaType: 3, pixelW: 100, pixelH: 100, duration: 5, uti: nil) == 0)
  }

  @Test func snapshotOverloadMatches() {
    let snap = AssetSnapshot(id: "a", mediaType: MediaKind.image, pixelW: 4000, pixelH: 3000, uti: "public.jpeg")
    #expect(SizeEstimator.estimate(snap) == 10_800_000)
    #expect(snap.isVideo == false)
    #expect(AssetSnapshot(id: "s", mediaType: 1, subtypes: MediaSubtype.screenshot | MediaSubtype.hdr).has(MediaSubtype.screenshot))
  }
}

/// Photos too small to be Squish candidates even as PNG never get their type looked up. They are rarely camera HEICs:
/// mostly images saved from messaging apps and the web, nearly all JPEG. The HEIC rate (0.35) put them at 0.39x the
/// JPEG rate (0.9); they use 0.6 B/px, under the JPEG rate (those apps re-encode at lower quality) but close to it.
struct UntypedPhotoEstimateTests {
  @Test func theLookupFloorIsThreeMegabytesAtThePNGRate() {
    #expect(SizeEstimator.typeLookupMinimumPixels == 1_875_000)
    let png = { (pixels: Int) in
      SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: pixels, pixelH: 1, duration: 0, uti: "public.png")
    }
    #expect(png(SizeEstimator.typeLookupMinimumPixels) <= SizeEstimator.squishPhotoMinimumBytes)
    #expect(png(SizeEstimator.typeLookupMinimumPixels + 1) > SizeEstimator.squishPhotoMinimumBytes)
  }

  @Test func smallUntypedPhotosUseTheMessagingRate() {
    // A WhatsApp-style 1280 x 960 JPEG (1.23 MP).
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1280, pixelH: 960, duration: 0, uti: nil) == 737_280)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1000, pixelH: 1000, duration: 0, uti: nil) == 600_000)
    // Below the floor only: from the floor up the type gets looked up, and the HEIC rate holds until it is.
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1875, pixelH: 1000, duration: 0, uti: nil) == 656_250)
    // Still under the JPEG rate: the estimate errs low.
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1280, pixelH: 960, duration: 0, uti: "public.jpeg")
            > SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1280, pixelH: 960, duration: 0, uti: nil))
  }

  @Test func smallUntypedScreenshotsKeepTheScreenshotCap() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1000, pixelH: 1000, duration: 0, uti: nil,
                                   isScreenshot: true) == 400_000)
  }
}

struct SnapshotFrameRateTests {
  @Test func highFrameRateSubtypeUsesTheSixtyFpsTier() {
    let normal = AssetSnapshot(id: "n", mediaType: MediaKind.video, pixelW: 1920, pixelH: 1080, duration: 10)
    let fast = AssetSnapshot(id: "f", mediaType: MediaKind.video, subtypes: MediaSubtype.videoHighFrameRate,
                             pixelW: 1920, pixelH: 1080, duration: 10)
    #expect(SizeEstimator.frameRate(of: normal) == 30)
    #expect(SizeEstimator.frameRate(of: fast) == 60)
    #expect(SizeEstimator.estimate(normal) == 12_500_000)
    #expect(SizeEstimator.estimate(fast) == 22_500_000)
  }

  @Test func fourKIsUnaffectedByFrameRate() {
    let fast = AssetSnapshot(id: "f", mediaType: MediaKind.video, subtypes: MediaSubtype.videoHighFrameRate,
                             pixelW: 3840, pixelH: 2160, duration: 10)
    #expect(SizeEstimator.estimate(fast) == 56_250_000)
  }
}

/// Screenshots are PNGs of mostly flat UI. Calibrated on 16 real 1284×2778 PNG captures from an iPhone 13 Pro Max
/// (device QA, 2026-10-23): median 0.12, max 0.40 bytes per pixel. The 1.6 B/px PNG rate (photographic PNG) put
/// 2,523 screenshots at 11.2 GB; screenshots now use the measured maximum, 0.40 B/px.
struct ScreenshotEstimateTests {
  @Test func aScreenshotPNGUsesTheCalibratedRate() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1284, pixelH: 2778, duration: 0, uti: "public.png",
                                   isScreenshot: true) == 1_426_780)
  }

  @Test func otherPNGsKeepThePhotographicRate() {
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1000, pixelH: 1000, duration: 0, uti: "public.png")
            == 1_600_000)
  }

  @Test func aScreenshotNeverEstimatesAboveItsContainerRate() {
    // A HEIC screenshot (some apps and iOS versions save them so) keeps the lower HEIC rate.
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1000, pixelH: 1000, duration: 0, uti: "public.heic",
                                   isScreenshot: true) == 350_000)
    #expect(SizeEstimator.estimate(mediaType: MediaKind.image, pixelW: 1000, pixelH: 1000, duration: 0, uti: "public.jpeg",
                                   isScreenshot: true) == 400_000)
  }

  @Test func snapshotsPassTheirScreenshotFlag() {
    let shot = AssetSnapshot(id: "s", mediaType: MediaKind.image, subtypes: MediaSubtype.screenshot, pixelW: 1000,
                             pixelH: 1000, uti: "public.png")
    #expect(SizeEstimator.estimate(shot) == 400_000)
  }
}
