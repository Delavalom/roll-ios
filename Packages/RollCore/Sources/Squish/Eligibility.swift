import Foundation

/// Why an asset can't be squished. Typed so the UI can explain it and the planner can skip it.
public enum IneligibilityReason: Sendable, Equatable, Codable {
  case unsupportedMediaType
  /// Not in the user's own library: a shared album or a computer-synced item.
  case notInUserLibrary
  case burst
  case spatialMedia
  case depthEffect
  case livePhoto
  case animated
  case slowMotion
  case cinematic
  /// The asset has edits (adjustment data or a rendered full-size copy); re-encoding would lose the edit history.
  case edited
  /// More than one resource (RAW+JPEG pair, paired video, ...): a re-encode would drop the extra parts.
  case multiResource
  /// The image file holds more than one frame (burst-like sequences, animations).
  case multiFrame
  /// The source has auxiliary data (gain map, depth, matte) the HEIC output could not carry.
  case auxiliaryDataNotPreserved
  /// An HDR or wide-colour video would come out in a different colour space.
  case colorSpaceChanged
  /// The file format isn't one v1 re-encodes safely: photos other than JPEG/PNG (HEIC is already compressed; DNG and
  /// ProRAW would lose their raw data), videos in ProRes, Apple Log or Dolby Vision, or an unknown container.
  case unsupportedFormat
}

/// What we know about a library asset before touching it. PhotoKit-free so it can be unit-tested.
public struct AssetFacts: Sendable, Equatable {
  public enum Resource: Sendable, Equatable {
    case photo, video
    /// A RAW or other alternate original.
    case alternatePhoto
    /// Full-size renders, adjustment data and adjustment base files: the asset has been edited.
    case edit
    /// The motion part of a Live Photo.
    case pairedVideo
    case other
  }

  public var mediaType: Int
  public var subtypes: Int
  public var resources: [Resource]
  public var burstIdentifier: String?
  /// `PHAsset.sourceType == .typeUserLibrary`. PhotoKit exposes no public flag for iCloud Shared Library items.
  public var isUserLibrary: Bool
  /// `PHAssetResource.uniformTypeIdentifier` of the asset's main resource.
  public var uti: String?

  public init(mediaType: Int, subtypes: Int, resources: [Resource], burstIdentifier: String?, isUserLibrary: Bool,
              uti: String? = nil) {
    self.mediaType = mediaType; self.subtypes = subtypes; self.resources = resources
    self.burstIdentifier = burstIdentifier; self.isUserLibrary = isUserLibrary; self.uti = uti
  }
}

public enum SquishEligibility {
  /// Only these photos are re-encoded: JPEG and PNG. HEIC is already compressed; DNG/ProRAW and the rest are refused.
  public static let photoFormats: Set<String> = ["public.jpeg", "public.png"]
  /// Containers for videos. The codec (ProRes, Dolby Vision, Apple Log) is checked on the exported file.
  public static let videoContainers: Set<String> = ["com.apple.quicktime-movie", "public.mpeg-4", "com.apple.m4v-video"]

  /// The first reason this asset must not be squished, or `nil` when it may be.
  public static func reason(for facts: AssetFacts) -> IneligibilityReason? {
    let isImage = facts.mediaType == SquishCandidates.imageMediaType
    let isVideo = facts.mediaType == SquishCandidates.videoMediaType
    guard isImage || isVideo else { return .unsupportedMediaType }
    if !facts.isUserLibrary { return .notInUserLibrary }
    if facts.burstIdentifier != nil { return .burst }
    let sub = facts.subtypes
    if sub & SquishCandidates.spatialMedia != 0 { return .spatialMedia }
    if sub & SquishCandidates.photoDepthEffect != 0 { return .depthEffect }
    if sub & SquishCandidates.photoLive != 0 { return .livePhoto }
    if sub & SquishCandidates.photoAnimation != 0 { return .animated }
    if sub & SquishCandidates.videoHighFrameRate != 0 { return .slowMotion }
    if sub & SquishCandidates.videoCinematic != 0 { return .cinematic }
    if facts.resources.contains(.edit) { return .edited }
    let expected: AssetFacts.Resource = isVideo ? .video : .photo
    if facts.resources != [expected] { return .multiResource }
    let allowed = isVideo ? videoContainers : photoFormats
    guard let uti = facts.uti, allowed.contains(uti) else { return .unsupportedFormat }
    return nil
  }
}
