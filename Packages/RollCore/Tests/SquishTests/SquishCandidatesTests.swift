import Foundation
import Library
import Testing
@testable import Squish
import Store
#if canImport(Photos)
import Photos
#endif

private let MB: Int64 = 1_000_000

private func video(bytes: Int64, seconds: Double = 10, w: Int = 1920, h: Int = 1080, subtypes: Int = 0,
                   cloudOnly: Bool = false) -> AssetRecord {
  AssetRecord(id: "v", mediaType: 2, subtypes: subtypes, pixelW: w, pixelH: h, duration: seconds,
              estBytes: bytes, cloudOnly: cloudOnly)
}

private func photo(bytes: Int64, uti: String?, subtypes: Int = 0) -> AssetRecord {
  AssetRecord(id: "p", mediaType: 1, subtypes: subtypes, pixelW: 4000, pixelH: 3000, uti: uti, estBytes: bytes)
}

struct SquishCandidatesTests {
  @Test func subtypeConstantsMatchPhotoKit() {
    #expect(SquishCandidates.photoLive == 1 << 3)
    #expect(SquishCandidates.videoHighFrameRate == 1 << 17)
    #expect(SquishCandidates.videoCinematic == 1 << 21)
    #if canImport(Photos)
    #expect(SquishCandidates.photoLive == Int(PHAssetMediaSubtype.photoLive.rawValue))
    #expect(SquishCandidates.videoHighFrameRate == Int(PHAssetMediaSubtype.videoHighFrameRate.rawValue))
    #expect(SquishCandidates.videoCinematic == Int(PHAssetMediaSubtype.videoCinematic.rawValue))
    #expect(SquishCandidates.imageMediaType == PHAssetMediaType.image.rawValue)
    #expect(SquishCandidates.videoMediaType == PHAssetMediaType.video.rawValue)
    #endif
  }

  @Test func bigVideoIsCandidate() {
    #expect(SquishCandidates.isCandidate(video(bytes: 51 * MB, seconds: 600)))
  }

  @Test func smallLowBitrateVideoIsNot() {
    // 20 MB over 60 s is about 2.7 Mbps at 1080p, under the HEVC target.
    #expect(!SquishCandidates.isCandidate(video(bytes: 20 * MB, seconds: 60)))
  }

  @Test func smallButHighBitrateVideoIs() {
    // 30 MB over 6 s is 40 Mbps, far over 1.5x the 1080p target.
    #expect(SquishCandidates.isCandidate(video(bytes: 30 * MB, seconds: 6)))
  }

  @Test func bitrateTargetScalesWithResolution() {
    let hd = SquishCandidates.hevcTargetBitrate(pixelW: 1920, pixelH: 1080)
    let uhd = SquishCandidates.hevcTargetBitrate(pixelW: 3840, pixelH: 2160)
    let sd = SquishCandidates.hevcTargetBitrate(pixelW: 1280, pixelH: 720)
    #expect(sd < hd && hd < uhd)
  }

  @Test func sameBitrateIsCandidateOnlyAtLowerResolution() {
    // 12 MB over 10 s = 9.6 Mbps: fine for 4K, heavy for 720p.
    #expect(!SquishCandidates.isCandidate(video(bytes: 12 * MB, seconds: 10, w: 3840, h: 2160)))
    #expect(SquishCandidates.isCandidate(video(bytes: 12 * MB, seconds: 10, w: 1280, h: 720)))
  }

  @Test func videoWithoutDurationOrSizeUsesOnlyTheSizeRule() {
    var r = video(bytes: 10 * MB)
    r.duration = nil
    #expect(!SquishCandidates.isCandidate(r))
    r.duration = 0
    #expect(!SquishCandidates.isCandidate(r))
    r.estBytes = 80 * MB
    #expect(SquishCandidates.isCandidate(r))
  }

  @Test func excludedSubtypesAreNeverCandidates() {
    for sub in [SquishCandidates.videoHighFrameRate, SquishCandidates.videoCinematic] {
      #expect(!SquishCandidates.isCandidate(video(bytes: 500 * MB, subtypes: sub)))
    }
    #expect(!SquishCandidates.isCandidate(photo(bytes: 9 * MB, uti: "public.jpeg", subtypes: SquishCandidates.photoLive)))
    // Other subtypes (e.g. HDR, 1 << 1) don't disqualify.
    #expect(SquishCandidates.isCandidate(photo(bytes: 9 * MB, uti: "public.jpeg", subtypes: 1 << 1)))
  }

  @Test func photoRules() {
    #expect(SquishCandidates.isCandidate(photo(bytes: 4 * MB, uti: "public.jpeg")))
    #expect(SquishCandidates.isCandidate(photo(bytes: 4 * MB, uti: "public.png")))
    #expect(!SquishCandidates.isCandidate(photo(bytes: 3 * MB, uti: "public.jpeg")))  // must be over 3 MB
    #expect(!SquishCandidates.isCandidate(photo(bytes: 4 * MB, uti: "public.heic")))
    #expect(!SquishCandidates.isCandidate(photo(bytes: 4 * MB, uti: nil)))
  }

  @Test func deletedAndOtherMediaTypesAreSkipped() {
    var r = video(bytes: 500 * MB)
    r.deleted = true
    #expect(!SquishCandidates.isCandidate(r))
    var audio = video(bytes: 500 * MB)
    audio.mediaType = 3
    #expect(!SquishCandidates.isCandidate(audio))
  }

  @Test func cloudOnlyAssetsStayCandidates() {
    #expect(SquishCandidates.isCandidate(video(bytes: 500 * MB, cloudOnly: true)))
  }
}

/// The Indexer looks up file types only for photos that could be Squish candidates; Library mirrors Squish's photo
/// minimum to compute that floor (it doesn't depend on Squish).
struct TypeLookupFloorTests {
  @Test func theMirroredMinimumMatchesSquish() {
    #expect(SizeEstimator.squishPhotoMinimumBytes == SquishCandidates.minPhotoBytes)
  }
}
