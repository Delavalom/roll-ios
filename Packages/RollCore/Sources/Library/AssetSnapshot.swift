import Foundation

/// `PHAssetMediaType` raw values, kept as plain integers so the Store and tests need no PhotoKit.
public enum MediaKind {
  public static let image = 1
  public static let video = 2
}

/// `PHAssetMediaSubtype` bit values (stable SDK constants) for the flags Roll reads.
public enum MediaSubtype {
  public static let panorama = 1 << 0
  public static let hdr = 1 << 1
  public static let screenshot = 1 << 2
  public static let livePhoto = 1 << 3
  public static let depthEffect = 1 << 4
  public static let animation = 1 << 6
  public static let spatial = 1 << 10
  public static let videoHighFrameRate = 1 << 17
  public static let videoTimelapse = 1 << 18
  public static let videoScreenRecording = 1 << 19
  public static let videoCinematic = 1 << 21
}

/// A plain value copy of what PhotoKit reports about one asset.
public struct AssetSnapshot: Sendable, Equatable, Identifiable {
  /// `PHAsset.localIdentifier`.
  public var id: String
  public var mediaType: Int
  public var subtypes: Int
  /// Seconds since 1970, if known.
  public var created: Double?
  public var pixelW: Int
  public var pixelH: Int
  public var duration: Double
  public var isFavorite: Bool
  public var burstId: String?
  public var uti: String?
  /// `PHAsset.modificationDate`, seconds since 1970. Changes on edits and on metadata changes (favorite, say).
  public var modified: Double?

  public init(id: String, mediaType: Int, subtypes: Int = 0, created: Double? = nil, pixelW: Int = 0, pixelH: Int = 0,
              duration: Double = 0, isFavorite: Bool = false, burstId: String? = nil, uti: String? = nil,
              modified: Double? = nil) {
    self.id = id; self.mediaType = mediaType; self.subtypes = subtypes; self.created = created
    self.pixelW = pixelW; self.pixelH = pixelH; self.duration = duration; self.isFavorite = isFavorite
    self.burstId = burstId; self.uti = uti; self.modified = modified
  }

  public var isVideo: Bool { mediaType == MediaKind.video }
  public func has(_ subtype: Int) -> Bool { subtypes & subtype != 0 }
}
