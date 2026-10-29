import Foundation
import GRDB

/// Where an asset's Vision signals (and vector) came from.
public enum AnalysisSource: String, Codable, Sendable, DatabaseValueConvertible {
  /// The small local preview the library keeps for an original that is only in iCloud.
  case preview
  /// A full-size image: local, or downloaded by the opt-in "Improve with iCloud originals" pass.
  case full
}

/// Where the original resource is, from a direct check (`Repositories.setOriginalLocal`): reading the primary resource
/// with network access off. Thumbnails never decide it.
public enum AssetLocality: Sendable, Equatable {
  /// The original resource is on this iPhone.
  case onDevice
  /// The original resource is only in iCloud.
  case iCloud
  /// Not checked yet. Counts as iCloud for anything that promises space on the device.
  case unknown
}

/// One photo or video the library reported, plus everything Roll computed about it.
public struct AssetRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "asset"

  /// The canonical blur threshold: a `blur` score (Laplacian variance, see `Signals.BlurScore`)
  /// strictly below this counts as blurry. Ranking's Blurry preset reads it from here.
  public static let blurryBelow: Double = 25

  /// Blur and aesthetics are judged on a 256 px thumbnail (`Signals.BlurScore.analysisSide`). A preview smaller than
  /// that can't say whether a photo is blurry or poor, so quality filters skip it (`qualityTrusted`).
  public static let qualityAnalysisSide = 256

  /// False for rows analysed from an image smaller than `qualityAnalysisSide`, or of unknown size.
  public var qualityTrusted: Bool { (previewSide ?? 0) >= Self.qualityAnalysisSide }

  /// Feature prints and hashes from smaller images link unrelated photos: below this, a row isn't grouped. The indexer
  /// asks for 300 px (`IndexerConfig.thumbnailSide`); a `.fast` resize can come back a few pixels short (299), so the
  /// guard sits 4% under the request. The small local previews (median 120 px, device QA) stay far below it.
  public static let minimumGroupingSide = 288

  /// Whether the row may join duplicate and similar-shot groups (analysed from at least `minimumGroupingSide` px).
  public var groupable: Bool { (previewSide ?? 0) >= Self.minimumGroupingSide }

  public var id: String
  public var mediaType: Int
  public var subtypes: Int
  public var created: Double?
  public var pixelW: Int?
  public var pixelH: Int?
  public var duration: Double?
  public var isFavorite: Bool
  public var burstId: String?
  public var uti: String?
  public var estBytes: Int64
  public var cloudOnly: Bool
  public var embedded: Bool
  public var signalsDone: Bool
  public var blur: Double?
  public var aesthetic: Double?
  public var isUtility: Bool?
  public var sensitive: Bool?
  /// Perceptual hash. SQLite integers are signed, so the column holds the Int64 bit pattern.
  private var phashBits: Int64?
  public var phash: UInt64? {
    get { phashBits.map { UInt64(bitPattern: $0) } }
    set { phashBits = newValue.map { Int64(bitPattern: $0) } }
  }
  public var featurePrint: Data?
  public var deleted: Bool
  /// Seconds since 1970 when the asset was first seen missing from the library; nil while it is live.
  public var deletedAt: Double?
  /// Failed thumbnail loads (see `Schema.maxAttempts`).
  public var attempts: Int
  /// The library's modification date (seconds since 1970), library-owned like `uti`. A remembered squish refusal
  /// holds only while it is unchanged (see `SquishRefusalRecord`).
  public var modified: Double?
  /// Where the signals came from; nil until analysed (v6).
  public var source: AnalysisSource?
  /// The longer side, in pixels, of the image the signals were computed from (v7; a preview or a full thumbnail).
  public var previewSide: Int?
  /// Whether the original resource is on the device (v8): nil until checked.
  public var originalLocal: Bool?

  /// From the original-resource check only (`originalLocal`). `cloudOnly` is about thumbnails, not this.
  public var locality: AssetLocality {
    switch originalLocal {
    case true?: .onDevice
    case false?: .iCloud
    case nil: .unknown
    }
  }

  public init(id: String, mediaType: Int, subtypes: Int, created: Double? = nil, pixelW: Int? = nil, pixelH: Int? = nil,
              duration: Double? = nil, isFavorite: Bool = false, burstId: String? = nil, uti: String? = nil,
              estBytes: Int64 = 0, cloudOnly: Bool = false, embedded: Bool = false, signalsDone: Bool = false,
              blur: Double? = nil, aesthetic: Double? = nil, isUtility: Bool? = nil, sensitive: Bool? = nil,
              phash: UInt64? = nil, featurePrint: Data? = nil, deleted: Bool = false, deletedAt: Double? = nil,
              attempts: Int = 0, modified: Double? = nil, source: AnalysisSource? = nil, previewSide: Int? = nil,
              originalLocal: Bool? = nil) {
    self.id = id; self.mediaType = mediaType; self.subtypes = subtypes; self.created = created
    self.pixelW = pixelW; self.pixelH = pixelH; self.duration = duration; self.isFavorite = isFavorite
    self.burstId = burstId; self.uti = uti; self.estBytes = estBytes; self.cloudOnly = cloudOnly
    self.embedded = embedded; self.signalsDone = signalsDone; self.blur = blur; self.aesthetic = aesthetic
    self.isUtility = isUtility; self.sensitive = sensitive; self.phashBits = phash.map { Int64(bitPattern: $0) }
    self.featurePrint = featurePrint; self.deleted = deleted; self.deletedAt = deletedAt; self.attempts = attempts
    self.modified = modified; self.source = source; self.previewSide = previewSide
    self.originalLocal = originalLocal
  }

  private enum CodingKeys: String, CodingKey {
    case id, mediaType, subtypes, created, pixelW, pixelH, duration, isFavorite, burstId, uti, estBytes, cloudOnly
    case embedded, signalsDone, blur, aesthetic, isUtility, sensitive, featurePrint, deleted, deletedAt, attempts, modified
    case source, previewSide, originalLocal
    case phashBits = "phash"
  }
}

/// The Vision-derived columns for one asset. Committed with `Repositories.commitSignals`, which
/// writes exactly these (so `nil` clears a signal) and never touches `embedded`.
public struct SignalFields: Sendable, Equatable {
  public var id: String
  public var signalsDone: Bool
  public var blur: Double?
  public var aesthetic: Double?
  public var isUtility: Bool?
  public var sensitive: Bool?
  public var phash: UInt64?
  public var featurePrint: Data?
  /// The original is in iCloud (as seen with network access off).
  public var cloudOnly: Bool
  public var source: AnalysisSource?
  /// The preview's longer side in pixels when `source == .preview`.
  public var previewSide: Int?

  public init(id: String, signalsDone: Bool, blur: Double? = nil, aesthetic: Double? = nil, isUtility: Bool? = nil,
              sensitive: Bool? = nil, phash: UInt64? = nil, featurePrint: Data? = nil, cloudOnly: Bool = false,
              source: AnalysisSource? = nil, previewSide: Int? = nil) {
    self.id = id; self.signalsDone = signalsDone; self.blur = blur; self.aesthetic = aesthetic
    self.isUtility = isUtility; self.sensitive = sensitive; self.phash = phash
    self.featurePrint = featurePrint; self.cloudOnly = cloudOnly; self.source = source; self.previewSide = previewSide
  }
}

/// What library sync needs to know about a stored row (see `Repositories.assetRefs(ids:)`).
public struct AssetRef: Sendable, Equatable {
  public var id: String
  public var uti: String?
  public var deleted: Bool

  public init(id: String, uti: String?, deleted: Bool) {
    self.id = id; self.uti = uti; self.deleted = deleted
  }
}
