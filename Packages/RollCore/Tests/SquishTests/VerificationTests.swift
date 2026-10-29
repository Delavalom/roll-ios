import CryptoKit
import Foundation
import Testing
@testable import Squish

private func fp(video: Bool = false, w: Int = 4000, h: Int = 3000, albums: Set<String> = ["A"]) -> AssetFingerprint {
  AssetFingerprint(isVideo: video, duration: 10, pixelWidth: w, pixelHeight: h, creationDate: Date(timeIntervalSince1970: 1000),
                   modificationDate: Date(timeIntervalSince1970: 2000), isFavorite: true, isHidden: false, latitude: 1,
                   longitude: 2, albumIDs: albums)
}

struct VerificationTests {
  // MARK: dimensions of the copy

  @Test func photoCopyKeepsExactDimensions() {
    #expect(AssetFingerprint.mismatch(source: fp(), new: fp(), keep4K: false) == nil)
    #expect(AssetFingerprint.mismatch(source: fp(), new: fp(w: 4000, h: 2999), keep4K: false) == "dimensions differ")
    #expect(AssetFingerprint.mismatch(source: fp(), new: fp(w: 3000, h: 4000), keep4K: false) == "dimensions differ")
  }

  @Test func videoCopyHasTheExpectedDownscaledSize() {
    let src = fp(video: true, w: 3840, h: 2160)
    #expect(AssetFingerprint.mismatch(source: src, new: fp(video: true, w: 1920, h: 1080), keep4K: false) == nil)
    #expect(AssetFingerprint.mismatch(source: src, new: fp(video: true, w: 1920, h: 1081), keep4K: false) == nil, "within 2 px")
    #expect(AssetFingerprint.mismatch(source: src, new: fp(video: true, w: 1280, h: 720), keep4K: false) == "dimensions differ")
    #expect(AssetFingerprint.mismatch(source: src, new: src, keep4K: false) == "dimensions differ", "4K must have been downscaled")
    #expect(AssetFingerprint.mismatch(source: src, new: src, keep4K: true) == nil)
    let portrait = fp(video: true, w: 2160, h: 3840)
    #expect(AssetFingerprint.mismatch(source: portrait, new: fp(video: true, w: 1080, h: 1920), keep4K: false) == nil)
    #expect(AssetFingerprint.mismatch(source: portrait, new: fp(video: true, w: 1920, h: 1080), keep4K: false) == "dimensions differ",
            "aspect ratio must not flip")
  }

  // MARK: source decodes at the asset's size

  @Test func sourceDimensionsMatchEitherOrientation() {
    #expect(SourceCheck.dimensionsMatch(file: (4032, 3024), asset: (4032, 3024)))
    #expect(SourceCheck.dimensionsMatch(file: (4032, 3024), asset: (3024, 4032)), "PHAsset reports oriented sizes")
    #expect(!SourceCheck.dimensionsMatch(file: (320, 240), asset: (4032, 3024)), "thumbnail download")
    #expect(!SourceCheck.dimensionsMatch(file: (4032, 3023), asset: (4032, 3024)))
  }

  @Test func aTruncatedPhotoIsRefusedAsASource() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = dir.appendingPathComponent("good.jpg")
    try Fixtures.makeJPEG(at: good, width: 800, height: 600)
    try SourceCheck.verifyPhoto(good, assetWidth: 800, assetHeight: 600)
    #expect(throws: SquishError.verificationFailed("exported original does not match the library asset")) {
      try SourceCheck.verifyPhoto(good, assetWidth: 4000, assetHeight: 3000)
    }
    let cut = dir.appendingPathComponent("cut.jpg")
    let data = try Data(contentsOf: good)
    try data.prefix(data.count / 4).write(to: cut)
    #expect(throws: SquishError.self) { try SourceCheck.verifyPhoto(cut, assetWidth: 800, assetHeight: 600) }
  }

  // MARK: digest

  @Test func digestMatchesCryptoKit() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("x.bin")
    let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try data.write(to: url)
    let d = try FileDigest.of(url)
    #expect(d.bytes == 300_000)
    #expect(d.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }

  @Test func incrementalHasherAgreesWithTheFileDigest() {
    var h = FileDigest.Hasher()
    h.update(Data([1, 2, 3])); h.update(Data([4, 5]))
    #expect(h.finish() == FileDigest(bytes: 5, sha256: SHA256.hash(data: Data([1, 2, 3, 4, 5])).map { String(format: "%02x", $0) }.joined()))
  }

  // MARK: copy as stored in the library

  @Test func readBackMustBeOneResourceOfTheExpectedTypeSizeAndHash() {
    let digest = FileDigest(bytes: 100, sha256: "abc")
    let good = CopyReadBack(resources: [.photo], uti: "public.heic", bytes: 100, sha256: "abc")
    #expect(good.problem(expectedKind: .photo, expectedUTI: "public.heic", digest: digest) == nil)
    #expect(CopyReadBack(resources: [.photo, .photo], uti: "public.heic", bytes: 100, sha256: "abc")
      .problem(expectedKind: .photo, expectedUTI: "public.heic", digest: digest) == "copy does not have exactly one resource")
    #expect(CopyReadBack(resources: [.video], uti: "public.heic", bytes: 100, sha256: "abc")
      .problem(expectedKind: .photo, expectedUTI: "public.heic", digest: digest) == "copy does not have exactly one resource")
    #expect(CopyReadBack(resources: [.photo], uti: "public.jpeg", bytes: 100, sha256: "abc")
      .problem(expectedKind: .photo, expectedUTI: "public.heic", digest: digest) == "copy has an unexpected type")
    #expect(CopyReadBack(resources: [.photo], uti: "public.heic", bytes: 99, sha256: "abc")
      .problem(expectedKind: .photo, expectedUTI: "public.heic", digest: digest) == "copy size differs from the encoded file")
    #expect(CopyReadBack(resources: [.photo], uti: "public.heic", bytes: 100, sha256: "zzz")
      .problem(expectedKind: .photo, expectedUTI: "public.heic", digest: digest) == "copy content differs from the encoded file")
  }

  // MARK: commit guard

  private func prepared() -> Prepared {
    Prepared(assetID: "a", newAssetID: "n", originalBytes: 100, newBytes: 40, keep4K: false,
             verifiedOriginal: fp(), verifiedCopy: fp())
  }
  private func snap(_ f: AssetFingerprint, facts: AssetFacts? = nil) -> LibrarySnapshot {
    LibrarySnapshot(fingerprint: f, facts: facts ?? AssetFacts(mediaType: 1, subtypes: 0, resources: [.photo], burstIdentifier: nil,
                                                              isUserLibrary: true, uti: "public.jpeg"))
  }

  @Test func guardAllowsAnUnchangedPair() {
    #expect(CommitGuard.decide(prepared(), original: snap(fp()), copy: snap(fp())) == nil)
  }

  @Test func guardSkipsEveryChangeSinceVerification() {
    let p = prepared()
    #expect(CommitGuard.decide(p, original: nil, copy: snap(fp())) == .originalMissing)
    #expect(CommitGuard.decide(p, original: snap(fp()), copy: nil) == .copyMissing)
    var edited = fp(); edited.modificationDate = Date(timeIntervalSince1970: 3000)
    #expect(CommitGuard.decide(p, original: snap(edited), copy: snap(fp())) == .originalModified)
    let editedFacts = AssetFacts(mediaType: 1, subtypes: 0, resources: [.photo, .edit], burstIdentifier: nil, isUserLibrary: true, uti: "public.jpeg")
    #expect(CommitGuard.decide(p, original: snap(fp(), facts: editedFacts), copy: snap(fp())) == .ineligible(.edited))
    #expect(CommitGuard.decide(p, original: snap(fp(albums: ["A", "B"])), copy: snap(fp())) == .mismatch("album membership differs"))
    var fav = fp(); fav.isFavorite = false
    #expect(CommitGuard.decide(p, original: snap(fav), copy: snap(fp())) == .mismatch("favorite state differs"))
  }

  // MARK: disclosures

  @Test func limitationsNameWhatCannotBeTransferred() {
    let all = SquishLimitations.items.joined(separator: " ")
    #expect(all.contains("Captions, keywords and people tags you added by hand aren't kept."))
    #expect(all.contains("If you use iCloud Shared Library, squished items are moved to your Personal Library and removed for other participants."))
    #expect(SquishPlanner.transferLimitations == SquishLimitations.items)
  }
}
