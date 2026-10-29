#if DEBUG
import AVFoundation
import Foundation
import ImageIO
#if canImport(Photos) && os(iOS)
import Photos
#endif

// DEBUG-only device QA (docs/qa/). Read-only probes of media formats, plus the Dolby Vision export experiment, which
// writes only to a temporary file and never to the photo library. Release builds compile none of this file.
// Nothing here records identifiers or photo content: only format facts and sizes.

/// A video's format, as Squish's checks see it.
public struct QAVideoFormat: Codable, Sendable, Equatable {
  public var codec = ""
  public var width = 0
  public var height = 0
  public var fps: Double = 0
  public var durationSeconds: Double = 0
  public var dataRateBitsPerSecond: Double = 0
  public var bitsPerComponent: Int?
  public var transferFunction: String?
  public var colorPrimaries: String?
  public var yCbCrMatrix: String?
  /// Sample-description extension atoms (`dvcC`/`dvvC`/`dvwC` carry the Dolby Vision configuration; `hvcC`, ...).
  public var extensionAtoms: [String] = []
  /// What `VideoSquisher` refuses: "dolbyVision", "proRes", "appleLog", or nil.
  public var refusedAs: String?
  public var audioTracks = 0
  public var metadataTracks = 0
  public var containsHDR = false

  public init() {}
}

/// A photo's format, as Squish's checks see it.
public struct QAPhotoFormat: Codable, Sendable, Equatable {
  public var type: String?
  public var frames = 0
  public var width = 0
  public var height = 0
  public var colorModel: String?
  public var profile: String?
  public var depth: Int?
  public var auxiliary: [String] = []
  public var hasGPS = false
  public var hasExifDate = false

  public init() {}
}

public enum QAMediaProbe {
  public static func video(_ asset: AVAsset) async -> QAVideoFormat {
    var f = QAVideoFormat()
    f.durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
    f.audioTracks = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
    f.metadataTracks = (try? await asset.loadTracks(withMediaType: .metadata).count) ?? 0
    f.containsHDR = (try? await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo).isEmpty == false) ?? false
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return f }
    let size = (try? await track.load(.naturalSize)) ?? .zero
    let transform = (try? await track.load(.preferredTransform)) ?? .identity
    let upright = size.applying(transform)
    f.width = Int(abs(upright.width).rounded()); f.height = Int(abs(upright.height).rounded())
    f.fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
    f.dataRateBitsPerSecond = Double((try? await track.load(.estimatedDataRate)) ?? 0)
    guard let desc = try? await track.load(.formatDescriptions).first else { return f }
    describe(desc, into: &f)
    return f
  }

  static func describe(_ desc: CMFormatDescription, into f: inout QAVideoFormat) {
    f.codec = fourCC(CMFormatDescriptionGetMediaSubType(desc))
    func ext(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(desc, extensionKey: key) as? String }
    f.transferFunction = ext(kCMFormatDescriptionExtension_TransferFunction)
    f.colorPrimaries = ext(kCMFormatDescriptionExtension_ColorPrimaries)
    f.yCbCrMatrix = ext(kCMFormatDescriptionExtension_YCbCrMatrix)
    f.bitsPerComponent = (CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
      as? NSNumber)?.intValue
    if let atoms = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
      as? [String: Any] { f.extensionAtoms = atoms.keys.sorted() }
    f.refusedAs = VideoSquisher.unsupportedFormat(desc).map { "\($0)" }
  }

  static func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    guard bytes.allSatisfy({ (0x20..<0x7F).contains($0) }), let text = String(bytes: bytes, encoding: .ascii) else {
      return String(format: "0x%08x", code)
    }
    return text
  }

  public static func photo(_ data: Data) -> QAPhotoFormat {
    var f = QAPhotoFormat()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return f }
    f.type = CGImageSourceGetType(source) as String?
    f.frames = CGImageSourceGetCount(source)
    guard f.frames > 0 else { return f }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    f.width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
    f.height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
    f.colorModel = props[kCGImagePropertyColorModel] as? String
    f.profile = props[kCGImagePropertyProfileName] as? String
    f.depth = props[kCGImagePropertyDepth] as? Int
    f.hasGPS = props[kCGImagePropertyGPSDictionary] != nil
    f.hasExifDate = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] != nil
    f.auxiliary = PhotoSquisher.auxiliary(of: source).map { "\($0)" }.sorted()
    return f
  }
}

/// The Dolby Vision export experiment: does an HEVC export of a Dolby Vision clip keep Dolby Vision or HDR metadata?
public struct QAExportResult: Codable, Sendable, Equatable {
  public var preset: String
  public var compatible = false
  public var seconds: Double = 0
  public var inputFormat: QAVideoFormat
  public var outputFormat: QAVideoFormat?
  public var outputBytes: Int64?
  public var error: String?
}

public enum QADolbyVisionExperiment {
  public static let presets = [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHEVC1920x1080]

  /// Exports `asset` with `preset` to a file in `directory`, describes the output, then deletes the file.
  public static func run(_ asset: AVAsset, preset: String, directory: URL) async -> QAExportResult {
    let input = await QAMediaProbe.video(asset)
    var result = QAExportResult(preset: preset, inputFormat: input)
    let output = directory.appendingPathComponent("qa-dv-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: output) }
    result.compatible = await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mov)
    guard result.compatible, let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      result.error = "preset not compatible"
      return result
    }
    session.shouldOptimizeForNetworkUse = false
    let start = ContinuousClock.now
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try await session.export(to: output, as: .mov)
      let elapsed = ContinuousClock.now - start
      result.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      result.outputBytes = try? SquishVerify.fileSize(output)
      result.outputFormat = await QAMediaProbe.video(AVURLAsset(url: output))
    } catch {
      result.error = String(describing: type(of: error)) + ": " + (error as NSError).localizedDescription
    }
    return result
  }
}

#if canImport(Photos) && os(iOS)
/// What the squish flow would decide about an asset before any work (`SquishEligibility` on the gateway's facts).
public struct QAEligibility: Codable, Sendable, Equatable {
  /// `IneligibilityReason` as text, or nil when the up-front checks pass (format checks on the file come later).
  public var refusedAs: String?
  public var resources: [String]
  public var uti: String?
  public var isUserLibrary: Bool
}

extension ReplaceFlow {
  /// The up-front eligibility the real flow computes for `assetID` (same gateway, same rules). Read-only.
  public static func qaEligibility(assetID: String) async -> QAEligibility? {
    guard let asset = try? await PhotoKitGateway().inspect(assetID) else { return nil }
    let facts = asset.facts
    return QAEligibility(refusedAs: SquishEligibility.reason(for: facts).map { "\($0)" },
                         resources: facts.resources.map { "\($0)" }, uti: facts.uti, isUserLibrary: facts.isUserLibrary)
  }

  /// DEBUG device QA: the production flow with a fixed free-space reading (`-QAFakeAvailableBytes`), to check the
  /// insufficient-space refusal without filling the phone. Everything else is the real PhotoKit flow.
  public static func qa(journal: any SquishJournal, allowNetwork: Bool, background: any BackgroundExecution,
                        availableBytes: Int64) -> ReplaceFlow {
    let workspace = SquishWorkspace()
    return ReplaceFlow(gateway: PhotoKitGateway(), journal: journal, workspace: workspace,
                       space: SquishDiskSpace(available: { availableBytes }), background: background,
                       allowNetwork: allowNetwork)
  }
}
#endif
#endif
