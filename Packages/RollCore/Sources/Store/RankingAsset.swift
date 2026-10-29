import GRDB

/// The asset columns ranking reads, and nothing else (no metadata, no feature print), so a
/// candidates call over the whole library decodes 8 columns per row.
public struct RankingAsset: Sendable, Equatable, Identifiable {
  public var id: String
  public var mediaType: Int
  public var subtypes: Int
  public var estBytes: Int64
  public var blur: Double?
  public var aesthetic: Double?
  public var isUtility: Bool?
  public var sensitive: Bool?
  /// `AssetRecord.qualityTrusted`: blur and aesthetics come from an image big enough to judge.
  public var qualityTrusted: Bool

  public init(id: String, mediaType: Int, subtypes: Int, estBytes: Int64, blur: Double? = nil, aesthetic: Double? = nil,
              isUtility: Bool? = nil, sensitive: Bool? = nil, qualityTrusted: Bool = true) {
    self.id = id; self.mediaType = mediaType; self.subtypes = subtypes; self.estBytes = estBytes
    self.blur = blur; self.aesthetic = aesthetic; self.isUtility = isUtility; self.sensitive = sensitive
    self.qualityTrusted = qualityTrusted
  }

  public init(_ record: AssetRecord) {
    self.init(id: record.id, mediaType: record.mediaType, subtypes: record.subtypes, estBytes: record.estBytes,
              blur: record.blur, aesthetic: record.aesthetic, isUtility: record.isUtility, sensitive: record.sensitive,
              qualityTrusted: record.qualityTrusted)
  }
}

/// A swipefile's cheap pre-filter, evaluated in SQL by `Repositories.rankingCandidates` (and in
/// Swift by `matches`, which tests keep identical). Every field that is set must hold; the two
/// quality fields combine with OR: `blur < blurBelow OR aesthetic < aestheticBelow`. A NULL
/// signal never matches its condition.
public struct CandidateFilter: Sendable, Equatable, CustomStringConvertible {
  /// `mediaType = ?`
  public var mediaType: Int?
  /// `subtypes & ? != 0`
  public var subtypesAny: Int?
  /// `estBytes > ?`
  public var bytesAbove: Int64?
  /// `blur < ?` (OR'd with `aestheticBelow`)
  public var blurBelow: Double?
  /// `aesthetic < ?` (OR'd with `blurBelow`). No preset uses it: Blurry is `mediaType = image AND blur < ?` only, and
  /// there is no low-quality pile until the founder has seen samples (2026-10-29).
  public var aestheticBelow: Double?

  /// Every asset passes.
  public static let none = CandidateFilter()

  public init(mediaType: Int? = nil, subtypesAny: Int? = nil, bytesAbove: Int64? = nil, blurBelow: Double? = nil,
              aestheticBelow: Double? = nil) {
    self.mediaType = mediaType; self.subtypesAny = subtypesAny; self.bytesAbove = bytesAbove
    self.blurBelow = blurBelow; self.aestheticBelow = aestheticBelow
  }

  public func matches(_ asset: RankingAsset) -> Bool {
    if let mediaType, asset.mediaType != mediaType { return false }
    if let subtypesAny, asset.subtypes & subtypesAny == 0 { return false }
    if let bytesAbove, asset.estBytes <= bytesAbove { return false }
    if blurBelow != nil || aestheticBelow != nil {
      guard asset.qualityTrusted else { return false }
      let blurry = blurBelow.flatMap { limit in asset.blur.map { $0 < limit } } ?? false
      let poor = aestheticBelow.flatMap { limit in asset.aesthetic.map { $0 < limit } } ?? false
      if !blurry && !poor { return false }
    }
    return true
  }

  /// `AND`-prefixed SQL conditions on table alias `a`, with their arguments.
  var sql: (clause: String, arguments: StatementArguments) {
    var clause = ""
    var arguments = StatementArguments()
    if let mediaType { clause += " AND a.mediaType = ?"; arguments += [mediaType] }
    if let subtypesAny { clause += " AND (a.subtypes & ?) != 0"; arguments += [subtypesAny] }
    if let bytesAbove { clause += " AND a.estBytes > ?"; arguments += [bytesAbove] }
    var quality: [String] = []
    if let blurBelow { quality.append("a.blur < ?"); arguments += [blurBelow] }
    if let aestheticBelow { quality.append("a.aesthetic < ?"); arguments += [aestheticBelow] }
    if !quality.isEmpty {
      clause += " AND (\(quality.joined(separator: " OR ")))"
      // `AssetRecord.qualityTrusted`: analysed from an image at least the analysis size.
      clause += " AND COALESCE(a.previewSide, 0) >= ?"
      arguments += [AssetRecord.qualityAnalysisSide]
    }
    return (clause, arguments)
  }

  public var description: String {
    "CandidateFilter(mediaType: \(mediaType.map(String.init) ?? "-"), subtypesAny: \(subtypesAny.map(String.init) ?? "-"), "
      + "bytesAbove: \(bytesAbove.map(String.init) ?? "-"), blurBelow: \(blurBelow.map { "\($0)" } ?? "-"), "
      + "aestheticBelow: \(aestheticBelow.map { "\($0)" } ?? "-"))"
  }
}
