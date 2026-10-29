import AVFoundation
import CryptoKit
import Foundation
import ImageIO

// MARK: - Library state

/// What must match between an original and its copy. Taken from the library at verification time and again at commit.
public struct AssetFingerprint: Codable, Sendable, Equatable {
  public var isVideo: Bool
  public var duration: Double
  public var pixelWidth: Int
  public var pixelHeight: Int
  public var creationDate: Date?
  public var modificationDate: Date?
  public var isFavorite: Bool
  public var isHidden: Bool
  public var latitude: Double?
  public var longitude: Double?
  /// User albums (regular, writable) that contain the asset.
  public var albumIDs: Set<String>

  public init(isVideo: Bool, duration: Double, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, modificationDate: Date?,
              isFavorite: Bool, isHidden: Bool, latitude: Double?, longitude: Double?, albumIDs: Set<String>) {
    self.isVideo = isVideo; self.duration = duration; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    self.creationDate = creationDate; self.modificationDate = modificationDate; self.isFavorite = isFavorite
    self.isHidden = isHidden; self.latitude = latitude; self.longitude = longitude; self.albumIDs = albumIDs
  }

  /// `nil` when `new` is an acceptable replacement for `source`, otherwise a short reason.
  static func mismatch(source: AssetFingerprint, new: AssetFingerprint, keep4K: Bool) -> String? {
    if new.isVideo != source.isVideo { return "media type differs" }
    if new.pixelWidth <= 0 || new.pixelHeight <= 0 { return "new asset has no pixels" }
    if source.isVideo {
      if abs(new.duration - source.duration) > SquishVerify.durationTolerance { return "duration differs" }
      // Same aspect ratio, at the size the preset should have produced.
      let down = Downscale.forSource(w: source.pixelWidth, h: source.pixelHeight, keep4K: keep4K)
      let expectedW = down?.toW ?? source.pixelWidth, expectedH = down?.toH ?? source.pixelHeight
      if abs(new.pixelWidth - expectedW) > 2 || abs(new.pixelHeight - expectedH) > 2 { return "dimensions differ" }
    } else if new.pixelWidth != source.pixelWidth || new.pixelHeight != source.pixelHeight {
      return "dimensions differ"
    }
    if let date = source.creationDate {
      guard let newDate = new.creationDate else { return "creation date missing" }
      if abs(newDate.timeIntervalSince(date)) > 1 { return "creation date differs" }
    }
    if new.isFavorite != source.isFavorite { return "favorite state differs" }
    if new.isHidden != source.isHidden { return "hidden state differs" }
    if let lat = source.latitude, let lon = source.longitude {
      guard let nl = new.latitude, let no = new.longitude else { return "location missing" }
      if abs(nl - lat) > 1e-4 || abs(no - lon) > 1e-4 { return "location differs" }
    }
    if !source.albumIDs.isSubset(of: new.albumIDs) { return "album membership differs" }
    return nil
  }
}

struct LibrarySnapshot: Sendable, Equatable {
  var fingerprint: AssetFingerprint
  var facts: AssetFacts
}

/// Why `commitDeletes` left an original alone.
public enum SkipReason: Sendable, Equatable, Codable {
  case originalMissing
  case copyMissing
  /// The original's modification date moved since the copy was verified (an edit, or any other change).
  case originalModified
  case ineligible(IneligibilityReason)
  /// Favorite, hidden, location, albums, date or size no longer line up between original and copy.
  case mismatch(String)
}


/// The last look before a delete: decides, from the library as it is *now*, whether the original may go.
enum CommitGuard {
  static func decide(_ p: Prepared, original: LibrarySnapshot?, copy: LibrarySnapshot?) -> SkipReason? {
    guard let original else { return .originalMissing }
    guard let copy else { return .copyMissing }
    if !sameInstant(original.fingerprint.modificationDate, p.verifiedOriginal.modificationDate) { return .originalModified }
    if let reason = SquishEligibility.reason(for: original.facts) { return .ineligible(reason) }
    if let problem = AssetFingerprint.mismatch(source: original.fingerprint, new: copy.fingerprint, keep4K: p.keep4K) {
      return .mismatch(problem)
    }
    return nil
  }

  private static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case let (x?, y?): abs(x.timeIntervalSince(y)) < 0.001
    default: false
    }
  }
}

// MARK: - The copy as the library stores it

struct CopyReadBack: Sendable, Equatable {
  var resources: [AssetFacts.Resource]
  var uti: String?
  var bytes: Int64
  var sha256: String

  /// `nil` when the stored copy is exactly the file we encoded.
  func problem(expectedKind: AssetFacts.Resource, expectedUTI: String, digest: FileDigest) -> String? {
    if resources != [expectedKind] { return "copy does not have exactly one resource" }
    if uti != expectedUTI { return "copy has an unexpected type" }
    if bytes != digest.bytes { return "copy size differs from the encoded file" }
    if sha256 != digest.sha256 { return "copy content differs from the encoded file" }
    return nil
  }
}

struct FileDigest: Sendable, Equatable {
  var bytes: Int64
  var sha256: String

  /// Incremental form, for data that arrives in chunks.
  struct Hasher {
    private var inner = SHA256()
    private var count: Int64 = 0
    mutating func update(_ data: Data) { inner.update(data: data); count += Int64(data.count) }
    func finish() -> FileDigest {
      FileDigest(bytes: count, sha256: inner.finalize().map { String(format: "%02x", $0) }.joined())
    }
  }

  static func of(_ url: URL) throws -> FileDigest {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Hasher()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
    return hasher.finish()
  }
}

// MARK: - The exported original

/// Guards against truncated or thumbnail-sized downloads: the file must decode at the library asset's own size.
enum SourceCheck {
  static let mismatchMessage = "exported original does not match the library asset"

  /// PHAsset reports oriented sizes while files may store the unrotated ones, so either orientation counts.
  static func dimensionsMatch(file: (Int, Int), asset: (Int, Int)) -> Bool {
    (file.0 == asset.0 && file.1 == asset.1) || (file.0 == asset.1 && file.1 == asset.0)
  }

  static func verifyPhoto(_ url: URL, assetWidth: Int, assetHeight: Int) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let pixels = image.dataProvider?.data, CFDataGetLength(pixels) > 0,
          CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    else { throw SquishError.verificationFailed("exported original does not decode") }
    guard dimensionsMatch(file: (image.width, image.height), asset: (assetWidth, assetHeight)) else {
      throw SquishError.verificationFailed(mismatchMessage)
    }
  }

  static func verifyVideo(_ url: URL, assetWidth: Int, assetHeight: Int) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else {
      throw SquishError.verificationFailed("exported original does not decode")
    }
    let shown = size.applying(transform)
    guard dimensionsMatch(file: (Int(abs(shown.width).rounded()), Int(abs(shown.height).rounded())), asset: (assetWidth, assetHeight)) else {
      throw SquishError.verificationFailed(mismatchMessage)
    }
  }
}

// MARK: - What the user is told

public enum SquishLimitations {
  /// Things squishing cannot carry over. PhotoKit offers no way to copy these, so the confirm sheet lists them.
  public static let items: [String] = [
    "Captions, keywords and people tags you added by hand aren't kept.",
    "Membership in shared albums isn't kept.",
    "If you use iCloud Shared Library, squished items are moved to your Personal Library and removed for other participants.",
  ]
}
