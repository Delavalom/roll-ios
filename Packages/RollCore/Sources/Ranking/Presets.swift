import Store

/// The built-in swipefiles (spec §5). Each one narrows the library with a cheap signal filter,
/// then ranks by embedding similarity to its prompts plus a signal boost. Big videos rank by
/// estimated bytes only. Custom swipefiles have no preset: every asset is a candidate, no boost.
public enum Preset: String, CaseIterable, Sendable {
  case screenshots, blurry, memes, receipts, privateStuff, bigVideos

  // PhotoKit raw values, kept here so Ranking doesn't import Photos.
  /// `PHAssetMediaType.image`.
  public static let imageMediaType = 1
  /// `PHAssetMediaType.video`.
  public static let videoMediaType = 2
  /// `PHAssetMediaSubtype.photoScreenshot`.
  public static let screenshotSubtype = 1 << 2

  /// Videos strictly larger than this (estimated, decimal MB) are big-video candidates.
  public static let bigVideoBytes: Int64 = 50_000_000

  public var name: String {
    switch self {
    case .screenshots: "Screenshots"
    case .blurry: "Blurry"
    case .memes: "Memes"
    case .receipts: "Receipts & documents"
    case .privateStuff: "Private"
    case .bigVideos: "Big videos"
    }
  }

  public var prompts: [String] {
    switch self {
    case .screenshots: ["a screenshot of a phone screen"]
    case .blurry: ["a blurry out of focus photo"]
    case .memes: ["a meme with caption text", "a reaction image", "an internet meme"]
    case .receipts: ["a photo of a receipt", "a photo of a document", "a whiteboard"]
    case .privateStuff: ["a nude photo", "an intimate private photo", "a photo in underwear"]
    case .bigVideos: []
    }
  }

  /// Big videos skip embeddings entirely and rank by `estBytes`.
  public var ranksByBytes: Bool { self == .bigVideos }

  public var defaultAction: SwipefileAction { self == .bigVideos ? .squish : .delete }

  /// Which assets may appear in this swipefile at all (before scoring). Evaluated in SQL by
  /// `Repositories.rankingCandidates`.
  public var filter: CandidateFilter {
    switch self {
    case .screenshots: CandidateFilter(subtypesAny: Self.screenshotSubtype)
    // Blurry photos only: a low aesthetic score isn't blur, and a video's blur score is one frame's
    // (docs/investigations/2026-10-29-similar-blurry.md).
    case .blurry: CandidateFilter(mediaType: Self.imageMediaType, blurBelow: AssetRecord.blurryBelow)
    case .memes: CandidateFilter(mediaType: Self.imageMediaType)
    case .receipts, .privateStuff: .none  // `isUtility` / `sensitive` only boost; the embedding decides
    case .bigVideos: CandidateFilter(mediaType: Self.videoMediaType, bytesAbove: Self.bigVideoBytes)
    }
  }

  /// `filter` applied in Swift.
  public func candidateFilter(_ record: AssetRecord) -> Bool { filter.matches(RankingAsset(record)) }

  /// Added to the embedding (or classifier) score.
  public func signalBoost(_ asset: RankingAsset) -> Float {
    switch self {
    case .screenshots:
      asset.subtypes & Self.screenshotSubtype != 0 ? 1 : 0
    case .blurry:
      asset.blur.map { Float(min(max(1 - $0 / AssetRecord.blurryBelow, 0), 1)) } ?? 0
    case .receipts:
      asset.isUtility == true ? 0.3 : 0
    case .privateStuff:
      asset.sensitive == true ? 0.5 : 0
    case .memes, .bigVideos:
      0
    }
  }

  public func signalBoost(_ record: AssetRecord) -> Float { signalBoost(RankingAsset(record)) }

  /// The preset a stored swipefile was made from; nil for custom swipefiles.
  public init?(swipefile: SwipefileRecord) {
    guard swipefile.kind == .preset, let raw = swipefile.preset else { return nil }
    self.init(rawValue: raw)
  }

  /// A fresh record for this preset, with the stable id `preset.<rawValue>`.
  public func swipefile(created: Double) -> SwipefileRecord {
    SwipefileRecord(id: "preset.\(rawValue)", name: name, kind: .preset, preset: rawValue, prompts: prompts,
                    action: defaultAction, created: created)
  }
}
