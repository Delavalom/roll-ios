import Foundation
import ImageIO
import Testing
@testable import Squish

struct PhotoSquisherTests {
  @Test(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
  func heicIsSmallerAndKeepsGPSAndOrientation() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("in.jpg")
    let output = dir.appendingPathComponent("out.heic")
    try Fixtures.makeJPEG(at: input)

    let result = try PhotoSquisher.squish(input: input, output: output)

    let inBytes = try Fixtures.fileSize(input), outBytes = try Fixtures.fileSize(output)
    print("PHOTO squish: \(inBytes) -> \(outBytes) bytes, ratio \(Double(outBytes) / Double(inBytes))")
    #expect(result.inputBytes == inBytes && result.outputBytes == outBytes)
    #expect(Double(outBytes) <= 0.8 * Double(inBytes))

    let inProps = try #require(Fixtures.properties(of: input))
    let outProps = try #require(Fixtures.properties(of: output))
    let inGPS = try #require(inProps[kCGImagePropertyGPSDictionary as String] as? [String: Any])
    let outGPS = try #require(outProps[kCGImagePropertyGPSDictionary as String] as? [String: Any])
    #expect(NSDictionary(dictionary: inGPS) == NSDictionary(dictionary: outGPS))
    #expect(outProps[kCGImagePropertyOrientation as String] as? Int == 6)
    #expect(outProps[kCGImagePropertyPixelWidth as String] as? Int == 4000)
    let exif = outProps[kCGImagePropertyExifDictionary as String] as? [String: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:10:23 12:00:00")
  }

  @Test(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
  func notSmallerOutputIsRejectedAndRemoved() throws {
    // A tiny flat JPEG is already minimal; HEIC can't beat it by 20%.
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("tiny.jpg")
    let output = dir.appendingPathComponent("tiny.heic")
    try Fixtures.makeJPEG(at: input, width: 16, height: 16)
    #expect(throws: SquishError.notSmaller) { try PhotoSquisher.squish(input: input, output: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func unreadableInputIsAnExportFailure() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
      _ = try PhotoSquisher.squish(input: dir.appendingPathComponent("nope.jpg"), output: dir.appendingPathComponent("o.heic"))
      Issue.record("expected a throw")
    } catch let e as SquishError {
      guard case .exportFailed = e else { Issue.record("expected exportFailed, got \(e)"); return }
    }
  }

  @Test(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
  func hdrGainMapSurvivesTheReencode() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("hdr.jpg"), output = dir.appendingPathComponent("hdr.heic")
    try Fixtures.makeJPEG(at: input, gainMap: true)
    #expect(Fixtures.hasGainMap(input), "fixture must carry a gain map")
    _ = try PhotoSquisher.squish(input: input, output: output)
    #expect(Fixtures.hasGainMap(output))
  }

  @Test func lostAuxiliaryDataIsDetected() {
    #expect(PhotoSquisher.missingAuxiliary(source: [.gainMap, .depth], output: [.depth]) == [.gainMap])
    #expect(PhotoSquisher.missingAuxiliary(source: [.gainMap], output: [.gainMap, .depth]).isEmpty)
    #expect(PhotoSquisher.missingAuxiliary(source: [], output: []).isEmpty)
  }

  @Test func multiFrameImagesAreRefusedBeforeEncoding() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("anim.gif"), output = dir.appendingPathComponent("anim.heic")
    try Fixtures.makeGIF(at: input)
    #expect(throws: SquishError.ineligible(.multiFrame)) { try PhotoSquisher.squish(input: input, output: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
  func outputDecodesFullyWithTheSameSizeAndColorProfile() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("p3.jpg"), output = dir.appendingPathComponent("p3.heic")
    try Fixtures.makeJPEG(at: input)
    _ = try PhotoSquisher.squish(input: input, output: output)
    let src = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(image.width == 4000 && image.height == 3000)
    #expect(Fixtures.properties(of: output)?[kCGImagePropertyProfileName as String] as? String
            == Fixtures.properties(of: input)?[kCGImagePropertyProfileName as String] as? String)
  }

  // MARK: Metadata

  private func dicts(exif: [String: Any] = [:], gps: [String: Any] = [:], tiff: [String: Any] = [:], iptc: [String: Any] = [:],
                     orientation: Int? = 6) -> [String: Any] {
    var d: [String: Any] = [:]
    if !exif.isEmpty { d[kCGImagePropertyExifDictionary as String] = exif }
    if !gps.isEmpty { d[kCGImagePropertyGPSDictionary as String] = gps }
    if !tiff.isEmpty { d[kCGImagePropertyTIFFDictionary as String] = tiff }
    if !iptc.isEmpty { d[kCGImagePropertyIPTCDictionary as String] = iptc }
    if let orientation { d[kCGImagePropertyOrientation as String] = orientation }
    return d
  }

  @Test func everySourceMetadataKeyMustSurvive() {
    let src = dicts(exif: ["DateTimeOriginal": "2020:01:02 03:04:05", "UserComment": "hi"], gps: ["Latitude": 1.0],
                    tiff: ["Make": "Apple"], iptc: ["Keywords": ["family"]])
    #expect(PhotoSquisher.metadataProblem(source: src, output: src) == nil)
    #expect(PhotoSquisher.metadataProblem(source: src, output: dicts(exif: ["DateTimeOriginal": "2020:01:02 03:04:05"], gps: ["Latitude": 1.0],
                                                                      tiff: ["Make": "Apple"], iptc: ["Keywords": ["family"]]))
            == "Exif metadata dropped: UserComment")
    #expect(PhotoSquisher.metadataProblem(source: src, output: dicts(exif: ["DateTimeOriginal": "2020:01:02 03:04:05", "UserComment": "hi"],
                                                                      tiff: ["Make": "Apple"], iptc: ["Keywords": ["family"]]))
            == "GPS metadata dropped: Latitude")
    #expect(PhotoSquisher.metadataProblem(source: src, output: dicts(exif: ["DateTimeOriginal": "2020:01:02 03:04:05", "UserComment": "hi"],
                                                                      gps: ["Latitude": 1.0], tiff: ["Make": "Apple"]))
            == "IPTC metadata dropped: Keywords")
  }

  @Test func outputMayGainKeys() {
    let src = dicts(exif: ["DateTimeOriginal": "x"])
    #expect(PhotoSquisher.metadataProblem(source: src, output: dicts(exif: ["DateTimeOriginal": "x", "ColorSpace": 1])) == nil)
  }

  @Test func orientationMustBePreserved() {
    #expect(PhotoSquisher.metadataProblem(source: dicts(orientation: 6), output: dicts(orientation: 1)) == "orientation changed")
    #expect(PhotoSquisher.metadataProblem(source: dicts(orientation: nil), output: dicts(orientation: 1)) == nil)
  }

  @Test func iptcDatesMayDropOnlyWhenTheExifDatesMatch() {
    let iptc: [String: Any] = ["DateCreated": "20200102", "TimeCreated": "030405", "Keywords": ["k"]]
    let exif: [String: Any] = ["DateTimeOriginal": "2020:01:02 03:04:05"]
    let src = dicts(exif: exif, iptc: iptc)
    let out = dicts(exif: exif, iptc: ["Keywords": ["k"]])
    #expect(PhotoSquisher.metadataProblem(source: src, output: out) == nil, "documented: ImageIO folds IPTC dates into EXIF")
    let shifted = dicts(exif: ["DateTimeOriginal": "2021:01:02 03:04:05"], iptc: ["Keywords": ["k"]])
    #expect(PhotoSquisher.metadataProblem(source: src, output: shifted) == "IPTC metadata dropped: DateCreated, TimeCreated")
    // Dropping a real IPTC field is never accepted.
    #expect(PhotoSquisher.metadataProblem(source: src, output: dicts(exif: exif)) == "IPTC metadata dropped: Keywords")
  }

  @Test(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
  func aRichPhoneStyleJPEGKeepsAllItsMetadata() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("rich.jpg"), output = dir.appendingPathComponent("rich.heic")
    try Fixtures.makeJPEG(at: input, width: 2400, height: 1800, extraProperties: [
      kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCaptionAbstract as String: "IPTC caption",
                                                 kCGImagePropertyIPTCKeywords as String: ["family"],
                                                 kCGImagePropertyIPTCDateCreated as String: "20261023",
                                                 kCGImagePropertyIPTCTimeCreated as String: "120000"],
      kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:10:23 12:00:00",
                                                 kCGImagePropertyExifOffsetTimeOriginal as String: "+09:00",
                                                 kCGImagePropertyExifUserComment as String: "user comment"],
      kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple", kCGImagePropertyTIFFModel as String: "iPhone"],
    ])
    _ = try PhotoSquisher.squish(input: input, output: output)
    let out = try #require(Fixtures.properties(of: output))
    let exif = out[kCGImagePropertyExifDictionary as String] as? [String: Any]
    #expect(exif?[kCGImagePropertyExifUserComment as String] as? String == "user comment")
    #expect(exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String == "+09:00")
  }

  @Test(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
  func aCMYKSourceIsRefusedBecauseTheOutputWouldChangeColorModel() throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("cmyk.jpg"), output = dir.appendingPathComponent("cmyk.heic")
    try Fixtures.makeCMYKJPEG(at: input)
    #expect(throws: SquishError.ineligible(.colorSpaceChanged)) { try PhotoSquisher.squish(input: input, output: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }
}
