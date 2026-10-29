import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Squish

private func description(codec: CMVideoCodecType, extensions: [CFString: Any] = [:]) -> CMFormatDescription {
  var desc: CMVideoFormatDescription?
  CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 1920, height: 1080,
                                 extensions: extensions.isEmpty ? nil : extensions as CFDictionary, formatDescriptionOut: &desc)
  return desc!
}

struct VideoFormatTests {
  @Test func ordinaryCodecsAreAccepted() {
    #expect(VideoSquisher.unsupportedFormat(description(codec: kCMVideoCodecType_HEVC)) == nil)
    #expect(VideoSquisher.unsupportedFormat(description(codec: kCMVideoCodecType_H264)) == nil)
  }

  @Test func proResIsRefused() {
    for codec in [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes4444,
                  kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444XQ,
                  kCMVideoCodecType_AppleProResRAW] {
      #expect(VideoSquisher.unsupportedFormat(description(codec: codec)) == .proRes)
    }
  }

  @Test func dolbyVisionIsRefusedByCodecOrConfigurationAtom() {
    #expect(VideoSquisher.unsupportedFormat(description(codec: kCMVideoCodecType_DolbyVisionHEVC)) == .dolbyVision)
    let atoms: [String: Any] = ["dvcC": Data([1, 0, 0, 0])]
    let hevcWithDV = description(codec: kCMVideoCodecType_HEVC,
                                 extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms])
    #expect(VideoSquisher.unsupportedFormat(hevcWithDV) == .dolbyVision)
    let atoms2: [String: Any] = ["dvvC": Data([1, 0, 0, 0])]
    let hevcWithDV2 = description(codec: kCMVideoCodecType_HEVC,
                                  extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms2])
    #expect(VideoSquisher.unsupportedFormat(hevcWithDV2) == .dolbyVision)
  }

  @Test func appleLogIsRefused() {
    let log = description(codec: kCMVideoCodecType_HEVC,
                          extensions: [kCMFormatDescriptionExtension_LogTransferFunction: kCMFormatDescriptionLogTransferFunction_AppleLog])
    #expect(VideoSquisher.unsupportedFormat(log) == .appleLog)
  }

  @Test(.enabled(if: Fixtures.hasHEVCHardwareEncoder, "no HEVC hardware encoder on this host"))
  func aProResFileIsRefusedBeforeExport() async throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("prores.mov"), output = dir.appendingPathComponent("out.mov")
    try await Fixtures.makeVideo(at: input, seconds: 1, fps: 10, width: 320, height: 240, codec: .proRes422)
    await #expect(throws: SquishError.ineligible(.unsupportedFormat)) {
      try await VideoSquisher.squish(input: input, output: output, keep4K: false)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  // MARK: Colour comparison

  private typealias Color = VideoSquisher.ColorSignature

  @Test func untaggedSourcesMayBeTaggedByTheEncoder() {
    let before = Color(), after = Color(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", bitsPerComponent: 8)
    #expect(!before.changed(to: after))
  }

  @Test func hdrTagsMustSurvive() {
    let hlg = Color(primaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", matrix: "ITU_R_2020", bitsPerComponent: 10)
    #expect(!hlg.changed(to: hlg))
    #expect(hlg.changed(to: Color(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", bitsPerComponent: 8)))
    #expect(hlg.changed(to: Color(primaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", matrix: "ITU_R_709_2", bitsPerComponent: 10)),
            "the matrix counts too")
    #expect(hlg.changed(to: Color(primaries: "ITU_R_2020", transfer: nil, matrix: "ITU_R_2020", bitsPerComponent: 10)))
  }

  @Test func onlyTagsTheSourceHasAreCompared() {
    let before = Color(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2")
    #expect(!before.changed(to: Color(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2")))
  }
}
