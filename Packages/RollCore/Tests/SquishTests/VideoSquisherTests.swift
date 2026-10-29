import AVFoundation
import Foundation
import Testing
@testable import Squish

struct VideoSquisherTests {
  @Test(.enabled(if: Fixtures.hasHEVCHardwareEncoder, "no HEVC hardware encoder on this host"))
  func hevcExportIsSmallerKeepsDurationAndLocation() async throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("in.mov")
    let output = dir.appendingPathComponent("out.mov")
    try await Fixtures.makeVideo(at: input, audio: true)
    #expect(try await Fixtures.locationItems(in: input).count == 1, "fixture must carry location metadata")

    let result = try await VideoSquisher.squish(input: input, output: output, keep4K: false)

    let inBytes = try Fixtures.fileSize(input), outBytes = try Fixtures.fileSize(output)
    print("VIDEO squish: \(inBytes) -> \(outBytes) bytes, ratio \(Double(outBytes) / Double(inBytes))")
    #expect(result.inputBytes == inBytes && result.outputBytes == outBytes)
    #expect(result.bytesSaved == inBytes - outBytes)
    #expect(Double(outBytes) <= 0.8 * Double(inBytes))

    let inAsset = AVURLAsset(url: input), outAsset = AVURLAsset(url: output)
    let dIn = try await inAsset.load(.duration).seconds, dOut = try await outAsset.load(.duration).seconds
    #expect(abs(dIn - dOut) <= 0.1)

    let track = try #require(try await outAsset.loadTracks(withMediaType: .video).first)
    let desc = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_HEVC)

    #expect(try await inAsset.loadTracks(withMediaType: .audio).count == 1, "fixture must carry audio")
    // The audio track survives, and the output decodes a frame.
    #expect(try await outAsset.loadTracks(withMediaType: .audio).count == 1)
    _ = try await AVAssetImageGenerator(asset: outAsset).image(at: .zero)

    let items = try await Fixtures.locationItems(in: output)
    #expect(items.count == 1)
    #expect(try await items.first?.load(.stringValue) == Fixtures.gpsLocation)
  }

  @Test func notSmallerOutputIsRejectedAndRemoved() async throws {
    // A tiny, low-bitrate clip can't shrink by 20%, so the squisher must refuse it and leave no output.
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("in.mov")
    let output = dir.appendingPathComponent("out.mov")
    try await Fixtures.makeVideo(at: input, seconds: 1, fps: 10, width: 320, height: 240, bitrate: 50_000)
    await #expect(throws: SquishError.notSmaller) {
      try await VideoSquisher.squish(input: input, output: output, keep4K: false)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func missingInputIsAnExportFailure() async throws {
    let dir = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
      _ = try await VideoSquisher.squish(input: dir.appendingPathComponent("nope.mov"),
                                         output: dir.appendingPathComponent("out.mov"), keep4K: false)
      Issue.record("expected a throw")
    } catch let e as SquishError {
      guard case .exportFailed = e else { Issue.record("expected exportFailed, got \(e)"); return }
    }
  }

  @Test func presetChoiceFollowsKeep4K() {
    #expect(VideoSquisher.presetName(keep4K: false) == AVAssetExportPresetHEVC1920x1080)
    #expect(VideoSquisher.presetName(keep4K: true) == AVAssetExportPresetHEVCHighestQuality)
  }
}
