import Foundation

/// Words read from one image, for `Repositories.commitText`. `side` is the long side in pixels of the image that was
/// read; nil means no usable image could be loaded (in iCloud, or only a small preview), so `text` is empty and a pass
/// that may use the network tries again (see `Repositories.textCandidateIds`).
public struct TextFields: Sendable, Equatable {
  public var id: String
  public var text: String
  /// The reader that produced `text` (`TextIndexer.revision`). Rows of another revision are read again.
  public var revision: String
  public var side: Int?

  public init(id: String, text: String, revision: String, side: Int?) {
    self.id = id; self.text = text; self.revision = revision; self.side = side
  }
}

/// A stored `assetText` row.
public struct TextRecord: Sendable, Equatable {
  public var assetId: String
  public var text: String
  /// `TextTerms.terms(text)` joined by spaces: what the keyword index holds.
  public var terms: String
  public var revision: String
  public var side: Int?
  public var readAt: Double
}

/// Which images get their words read: photos that are screenshots, or that Vision's aesthetics request called
/// `isUtility` (receipts, documents, notes, other non-photographic captures). `isUtility` comes from the signal pass, so
/// an image is read only once its signals are done. Videos are never read.
public enum TextGate {
  /// `MediaKind.image` and `MediaSubtype.screenshot` (Library), repeated here because Store doesn't depend on Library
  /// (a test checks they agree).
  public static let imageMediaType = 1
  public static let screenshotSubtype = 1 << 2

  public static func wantsText(mediaType: Int, subtypes: Int, isUtility: Bool?) -> Bool {
    mediaType == imageMediaType && (subtypes & screenshotSubtype != 0 || isUtility == true)
  }

  /// `wantsText` for live, analysed rows, in SQL. Must stay identical to the `asset_textGated` partial index's WHERE
  /// clause (Schema v10), or SQLite can't use the index.
  static let candidateWhere = "deleted = 0 AND mediaType = 1 AND signalsDone = 1 AND ((subtypes & 4) != 0 OR isUtility = 1)"
}

/// Search terms of a text: lowercased, diacritics folded, split on anything that isn't a letter or digit, at least two
/// characters, each once in first-seen order. The same rule as typed queries (`SearchTerms.terms` in Ranking), so a
/// word typed and a word read always meet in the keyword index ("@Uber" and "uber", "Café" and "cafe").
public enum TextTerms {
  public static func terms(_ text: String) -> [String] {
    var seen = Set<String>()
    return text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 2 && seen.insert($0).inserted }
  }
}
