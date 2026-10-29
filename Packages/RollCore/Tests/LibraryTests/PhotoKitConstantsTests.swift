#if canImport(Photos)
import Photos
import Testing
@testable import Library

/// PhotoKit exists on macOS too, so the hard-coded constants can be checked against the SDK here.
struct PhotoKitConstantsTests {
  @Test func mediaKindMatchesPHAssetMediaType() {
    #expect(MediaKind.image == PHAssetMediaType.image.rawValue)
    #expect(MediaKind.video == PHAssetMediaType.video.rawValue)
  }

  @Test func mediaSubtypesMatchPHAssetMediaSubtype() {
    #expect(MediaSubtype.panorama == Int(PHAssetMediaSubtype.photoPanorama.rawValue))
    #expect(MediaSubtype.hdr == Int(PHAssetMediaSubtype.photoHDR.rawValue))
    #expect(MediaSubtype.screenshot == Int(PHAssetMediaSubtype.photoScreenshot.rawValue))
    #expect(MediaSubtype.livePhoto == Int(PHAssetMediaSubtype.photoLive.rawValue))
    #expect(MediaSubtype.depthEffect == Int(PHAssetMediaSubtype.photoDepthEffect.rawValue))
    #expect(MediaSubtype.animation == Int(PHAssetMediaSubtype.photoAnimation.rawValue))
    #expect(MediaSubtype.spatial == Int(PHAssetMediaSubtype.spatialMedia.rawValue))
    #expect(MediaSubtype.videoHighFrameRate == Int(PHAssetMediaSubtype.videoHighFrameRate.rawValue))
    #expect(MediaSubtype.videoTimelapse == Int(PHAssetMediaSubtype.videoTimelapse.rawValue))
    #expect(MediaSubtype.videoScreenRecording == Int(PHAssetMediaSubtype.videoScreenRecording.rawValue))
    #expect(MediaSubtype.videoCinematic == Int(PHAssetMediaSubtype.videoCinematic.rawValue))
  }
}
#endif
