import Foundation

/// Words for keyword search. The text index (lane L3, OCR) and typed queries tokenize the same way,
/// with `terms(_:)`, so a query word matches the word as it was indexed.
public enum SearchTerms {
  /// Lowercased, diacritics folded ("Café" → "cafe"), split on everything that isn't a letter, mark
  /// or digit, words of at least 2 characters, duplicates dropped, first-seen order kept.
  public static func terms(_ text: String) -> [String] {
    var seen = Set<String>()
    return text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 2 && seen.insert($0).inserted }
  }

  /// `terms(_:)` minus stopwords and kind words ("screenshot", "photo"): those say what to look for,
  /// not what's written in it, and would let "a photo of my dog" reach half coverage on any text
  /// with "of" and "my". For queries only; indexing keeps every term.
  public static func queryTerms(_ text: String) -> [String] {
    terms(text).filter { !stopwords.contains($0) }
  }

  /// Small English and Spanish lists, already folded the way `terms` folds.
  static let stopwords: Set<String> = [
    "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "our", "your", "that",
    "this", "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were",
    "be", "it", "its", "some", "any", "all", "find", "show",
    "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot", "screenshots",
    "video", "videos", "clip", "clips",
    "de", "la", "el", "los", "las", "un", "una", "unos", "unas", "en", "con", "por", "para", "del", "al", "mi",
    "mis", "su", "sus", "que", "foto", "fotos", "imagen", "imagenes", "captura", "capturas",
  ]

  /// A query made only of codes ("k7q2lm", "inv2041") and long numbers ("4815162342": an order or
  /// phone number): every term has a digit and either a letter or at least 4 characters. Such a query
  /// means little to an embedding and everything to keyword search, so `LibrarySearch` weighs its
  /// words double and its meaning half. A short number ("417") alone isn't one.
  public static func isLookup(_ terms: [String]) -> Bool {
    !terms.isEmpty && terms.allSatisfy { term in
      term.contains(where: \.isNumber) && (term.contains(where: \.isLetter) || term.count >= 4)
    }
  }
}
