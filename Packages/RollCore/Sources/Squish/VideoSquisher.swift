import AVFoundation
import Foundation

/// Re-encodes a video to HEVC with `AVAssetExportSession`, keeping the source's metadata
/// (location, creation date) and refusing results that aren't clearly better.
public enum VideoSquisher {
  public static func presetName(keep4K: Bool) -> String {
    keep4K ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHEVC1920x1080
  }

  /// - Parameters:
  ///   - keep4K: `false` caps the output at 1080p; `true` keeps the source resolution.
  /// - Throws: `SquishError.notSmaller` / `.durationMismatch` (output deleted), `.cancelled`, `.unsupported`,
  ///   `.exportFailed`. On any throw no file is left at `output`.
  public static func squish(input: URL, output: URL, keep4K: Bool) async throws -> SquishResult {
    let inBytes: Int64
    do { inBytes = try SquishVerify.fileSize(input) } catch { throw SquishError.exportFailed(error) }
    let asset = AVURLAsset(url: input)
    let preset = presetName(keep4K: keep4K)
    let fileType: AVFileType = output.pathExtension.lowercased() == "mp4" ? .mp4 : .mov

    do {
      try await refuseUnsupportedFormat(asset)
      guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType)
      else { throw SquishError.unsupported }
      guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw SquishError.unsupported }
      session.shouldOptimizeForNetworkUse = false
      session.metadata = try await asset.load(.metadata)
      try? FileManager.default.removeItem(at: output)
      try await session.export(to: output, as: fileType)

      let outBytes = try SquishVerify.fileSize(output)
      guard SquishVerify.isSmallEnough(input: inBytes, output: outBytes) else { throw SquishError.notSmaller }
      try await verify(source: asset, output: AVURLAsset(url: output))
      return SquishResult(inputBytes: inBytes, outputBytes: outBytes)
    } catch {
      try? FileManager.default.removeItem(at: output)
      if let e = error as? SquishError { throw e }
      if error is CancellationError || (error as? AVError)?.code == .operationCancelled || Task.isCancelled {
        throw SquishError.cancelled
      }
      throw SquishError.exportFailed(error)
    }
  }

  // MARK: Formats v1 refuses

  enum UnsupportedFormat: Sendable, Equatable { case proRes, dolbyVision, appleLog }

  private static let proResCodecs: Set<CMVideoCodecType> = [
    kCMVideoCodecType_AppleProRes4444XQ, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422HQ,
    kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
    kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ,
  ]
  /// Dolby Vision codec tags ('dvh1', 'dvhe', 'dvav', 'dva1') and the configuration atoms HEVC/AVC carry it in.
  private static let dolbyVisionCodecs: Set<CMVideoCodecType> = [
    kCMVideoCodecType_DolbyVisionHEVC, 0x6476_6865 /* dvhe */, 0x6476_6176 /* dvav */, 0x6476_6131 /* dva1 */,
  ]
  private static let dolbyVisionAtoms: Set<String> = ["dvcC", "dvvC", "dvwC"]

  static func unsupportedFormat(_ desc: CMFormatDescription) -> UnsupportedFormat? {
    let codec = CMFormatDescriptionGetMediaSubType(desc)
    if proResCodecs.contains(codec) { return .proRes }
    if dolbyVisionCodecs.contains(codec) { return .dolbyVision }
    if let atoms = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
        as? [String: Any], !dolbyVisionAtoms.isDisjoint(with: atoms.keys) { return .dolbyVision }
    if CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_LogTransferFunction) != nil { return .appleLog }
    return nil
  }

  private static func refuseUnsupportedFormat(_ asset: AVURLAsset) async throws {
    for track in try await asset.loadTracks(withMediaType: .video) {
      for desc in try await track.load(.formatDescriptions) where unsupportedFormat(desc) != nil {
        throw SquishError.ineligible(.unsupportedFormat)
      }
    }
  }

  // MARK: Verification

  private static let checkedMediaTypes: [AVMediaType] = [.video, .audio, .metadata, .text, .subtitle, .closedCaption, .timecode]

  /// Duration within 0.1 s; same tracks per media type (so timed metadata and extra audio survive); each audio track's
  /// format and channel layout; video bit depth and colour; the output decodes.
  private static func verify(source: AVURLAsset, output: AVURLAsset) async throws {
    let dIn = try await source.load(.duration).seconds
    let dOut = try await output.load(.duration).seconds
    guard abs(dIn - dOut) <= SquishVerify.durationTolerance else { throw SquishError.durationMismatch }

    for type in checkedMediaTypes {
      let a = try await source.loadTracks(withMediaType: type), b = try await output.loadTracks(withMediaType: type)
      if a.count != b.count { throw SquishError.verificationFailed("\(type.rawValue) track count differs") }
    }
    guard let outVideo = try await output.loadTracks(withMediaType: .video).first,
          let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
      throw SquishError.verificationFailed("output has no video track")
    }

    let sourceAudio = try await source.loadTracks(withMediaType: .audio), outAudio = try await output.loadTracks(withMediaType: .audio)
    for (a, b) in zip(sourceAudio, outAudio) where try await audioSignature(a) != audioSignature(b) {
      throw SquishError.verificationFailed("audio format or channel layout differs")
    }

    do { _ = try await AVAssetImageGenerator(asset: output).image(at: .zero) }
    catch { throw SquishError.verificationFailed("output does not decode") }

    let before = try await colorSignature(of: sourceVideo), after = try await colorSignature(of: outVideo)
    if let depth = before.bitsPerComponent, depth != after.bitsPerComponent {
      throw SquishError.ineligible(.colorSpaceChanged)  // 10-bit must stay 10-bit
    }
    if before.changed(to: after) { throw SquishError.ineligible(.colorSpaceChanged) }
  }

  struct AudioSignature: Equatable {
    var formatID: UInt32
    var channels: UInt32
    var layoutTag: UInt32
  }

  static func audioSignature(_ track: AVAssetTrack) async throws -> AudioSignature {
    guard let desc = try await track.load(.formatDescriptions).first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
      return AudioSignature(formatID: 0, channels: 0, layoutTag: 0)
    }
    var size = 0
    let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &size)?.pointee.mChannelLayoutTag ?? 0
    return AudioSignature(formatID: asbd.mFormatID, channels: asbd.mChannelsPerFrame, layoutTag: layout)
  }

  struct ColorSignature: Equatable {
    var primaries: String?
    var transfer: String?
    var matrix: String?
    var bitsPerComponent: Int?
    /// Only tags the source has are compared: untagged sources (many plain SDR files) are re-tagged as BT.709 by the
    /// encoder, which is not a change.
    func changed(to after: ColorSignature) -> Bool {
      (primaries != nil && primaries != after.primaries) || (transfer != nil && transfer != after.transfer)
        || (matrix != nil && matrix != after.matrix)
    }
  }

  static func colorSignature(of track: AVAssetTrack) async throws -> ColorSignature {
    guard let desc = try await track.load(.formatDescriptions).first else { return ColorSignature() }
    func ext(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(desc, extensionKey: key) as? String }
    let bits = (CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
    return ColorSignature(primaries: ext(kCMFormatDescriptionExtension_ColorPrimaries),
                          transfer: ext(kCMFormatDescriptionExtension_TransferFunction),
                          matrix: ext(kCMFormatDescriptionExtension_YCbCrMatrix), bitsPerComponent: bits)
  }
}
