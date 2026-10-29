import Testing
@testable import Squish
#if canImport(Photos)
import Photos
#endif

private func facts(_ type: Int = 1, subtypes: Int = 0, resources: [AssetFacts.Resource] = [.photo],
                   burst: String? = nil, userLibrary: Bool = true, uti: String? = nil) -> AssetFacts {
  AssetFacts(mediaType: type, subtypes: subtypes, resources: resources, burstIdentifier: burst, isUserLibrary: userLibrary,
             uti: uti ?? (type == 2 ? "com.apple.quicktime-movie" : "public.jpeg"))
}

struct EligibilityTests {
  @Test func plainPhotoAndVideoAreEligible() {
    #expect(SquishEligibility.reason(for: facts()) == nil)
    #expect(SquishEligibility.reason(for: facts(2, resources: [.video])) == nil)
  }

  @Test func newSubtypesMatchPhotoKit() {
    #expect(SquishCandidates.spatialMedia == 1 << 10)
    #expect(SquishCandidates.photoDepthEffect == 1 << 4)
    #expect(SquishCandidates.photoAnimation == 1 << 6)
    #if canImport(Photos)
    #expect(SquishCandidates.spatialMedia == Int(PHAssetMediaSubtype.spatialMedia.rawValue))
    #expect(SquishCandidates.photoDepthEffect == Int(PHAssetMediaSubtype.photoDepthEffect.rawValue))
    #expect(SquishCandidates.photoAnimation == Int(PHAssetMediaSubtype.photoAnimation.rawValue))
    #endif
  }

  @Test func subtypeRefusals() {
    #expect(SquishEligibility.reason(for: facts(subtypes: SquishCandidates.spatialMedia)) == .spatialMedia)
    #expect(SquishEligibility.reason(for: facts(subtypes: SquishCandidates.photoDepthEffect)) == .depthEffect)
    #expect(SquishEligibility.reason(for: facts(subtypes: SquishCandidates.photoLive)) == .livePhoto)
    #expect(SquishEligibility.reason(for: facts(subtypes: SquishCandidates.photoAnimation)) == .animated)
    #expect(SquishEligibility.reason(for: facts(2, subtypes: SquishCandidates.videoHighFrameRate, resources: [.video])) == .slowMotion)
    #expect(SquishEligibility.reason(for: facts(2, subtypes: SquishCandidates.videoCinematic, resources: [.video])) == .cinematic)
    #expect(SquishEligibility.reason(for: facts(2, subtypes: SquishCandidates.spatialMedia, resources: [.video])) == .spatialMedia)
  }

  @Test func resourceRefusals() {
    #expect(SquishEligibility.reason(for: facts(resources: [.photo, .alternatePhoto])) == .multiResource)  // RAW+JPEG
    #expect(SquishEligibility.reason(for: facts(resources: [.photo, .pairedVideo])) == .multiResource)
    #expect(SquishEligibility.reason(for: facts(resources: [.photo, .edit])) == .edited)
    #expect(SquishEligibility.reason(for: facts(resources: [])) == .multiResource)
    #expect(SquishEligibility.reason(for: facts(resources: [.video])) == .multiResource, "photo asset with a video resource")
    #expect(SquishEligibility.reason(for: facts(2, resources: [.photo])) == .multiResource, "video asset with a photo resource")
  }

  @Test func burstAndLibraryRefusals() {
    #expect(SquishEligibility.reason(for: facts(burst: "B1")) == .burst)
    #expect(SquishEligibility.reason(for: facts(userLibrary: false)) == .notInUserLibrary)
  }

  @Test func otherMediaTypesAreRefused() {
    #expect(SquishEligibility.reason(for: facts(3)) == .unsupportedMediaType)
  }

  @Test func recordsWithBurstIdsOrNewSubtypesAreNotCandidates() {
    var r = AssetRecordFixtures.photo(bytes: 9_000_000)
    #expect(SquishCandidates.isCandidate(r))
    r.burstId = "B1"
    #expect(!SquishCandidates.isCandidate(r))
    for sub in [SquishCandidates.spatialMedia, SquishCandidates.photoDepthEffect, SquishCandidates.photoAnimation] {
      var s = AssetRecordFixtures.photo(bytes: 9_000_000)
      s.subtypes = sub
      #expect(!SquishCandidates.isCandidate(s))
    }
  }

  @Test func onlyJPEGAndPNGPhotosAreSquished() {
    #expect(SquishEligibility.reason(for: facts(uti: "public.jpeg")) == nil)
    #expect(SquishEligibility.reason(for: facts(uti: "public.png")) == nil)
    for uti in ["public.heic", "public.heif", "com.adobe.raw-image", "com.adobe.dng", "public.tiff", "com.compuserve.gif"] {
      #expect(SquishEligibility.reason(for: facts(uti: uti)) == .unsupportedFormat, "\(uti)")
    }
  }

  @Test func aPhotoWithoutAKnownTypeFailsClosed() {
    var f = facts()
    f.uti = nil
    #expect(SquishEligibility.reason(for: f) == .unsupportedFormat)
  }

  @Test func videoContainers() {
    for uti in ["com.apple.quicktime-movie", "public.mpeg-4", "com.apple.m4v-video"] {
      #expect(SquishEligibility.reason(for: facts(2, resources: [.video], uti: uti)) == nil, "\(uti)")
    }
    #expect(SquishEligibility.reason(for: facts(2, resources: [.video], uti: "public.avi")) == .unsupportedFormat)
  }

  @Test func resourceProblemsAreReportedBeforeFormat() {
    #expect(SquishEligibility.reason(for: facts(resources: [.photo, .alternatePhoto], uti: "com.adobe.raw-image")) == .multiResource)
  }
}
