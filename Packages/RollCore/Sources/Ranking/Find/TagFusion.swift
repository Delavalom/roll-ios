import Foundation

/// The texts a query embeds (V1): the bare query and its templates.
public enum FindQuery {
  /// `config.templates` with "{q}" replaced by `query` (a template without "{q}" gets the query appended), after the
  /// bare query when `includeBareQuery`. Never empty for a non-blank query; duplicates are dropped.
  public static func texts(for query: String, config: FindConfig) -> [String] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    var out: [String] = config.includeBareQuery ? [q] : []
    for template in config.templates {
      let t = template.contains("{q}") ? template.replacingOccurrences(of: "{q}", with: q) : template + " " + q
      if !out.contains(t) { out.append(t) }
    }
    return out.isEmpty ? [q] : out
  }
}

/// Tags as words (V4): what share of a query's words a photo's labels (Vision classifications, or any per-photo labels
/// the caller has) cover, through a small synonym table, so "soccer" finds a photo labelled "sport" + "ball".
public enum TagFusion {
  /// Query word → labels that count for it. Small on purpose: each entry is a guess the eval can check, and a wrong
  /// synonym adds noise to every query that uses the word. Keys and labels are folded like `SearchTerms.terms`, words
  /// joined by "_".
  public static let defaultSynonyms: [String: Set<String>] = [
    "soccer": ["soccer", "football", "sport", "ball", "stadium", "field"],
    "futbol": ["soccer", "football", "sport", "ball", "stadium", "field"],
    "football": ["football", "soccer", "american_football", "sport", "ball", "stadium"],
    "basketball": ["basketball", "sport", "ball", "court"],
    "baseball": ["baseball", "sport", "ball", "stadium"],
    "beach": ["beach", "shore", "sand", "ocean", "sea", "coast"],
    "playa": ["beach", "shore", "sand", "ocean", "sea", "coast"],
    "dog": ["dog", "puppy", "canine", "pet"],
    "perro": ["dog", "puppy", "canine", "pet"],
    "cat": ["cat", "kitten", "feline", "pet"],
    "gato": ["cat", "kitten", "feline", "pet"],
    "food": ["food", "meal", "dish", "dessert", "baked_goods"],
    "comida": ["food", "meal", "dish", "dessert"],
    "car": ["car", "automobile", "vehicle"],
    "carro": ["car", "automobile", "vehicle"],
    "snow": ["snow", "winter", "ski", "skiing"],
    "nieve": ["snow", "winter", "ski", "skiing"],
    "concert": ["concert", "stage", "music", "performance", "crowd"],
    "concierto": ["concert", "stage", "music", "performance", "crowd"],
    "birthday": ["birthday", "cake", "candle", "party"],
    "cumpleanos": ["birthday", "cake", "candle", "party"],
    "wedding": ["wedding", "bride", "groom", "ceremony", "wedding_dress"],
    "boda": ["wedding", "bride", "groom", "ceremony", "wedding_dress"],
  ]

  /// Share of `queryTerms` (folded content words, `SearchTerms.queryTerms`) for which some label equals the word or is
  /// one of its synonyms. 0 for no terms or no labels.
  public static func coverage(queryTerms: [String], labels: [String],
                              synonyms: [String: Set<String>] = defaultSynonyms) -> Double {
    guard !queryTerms.isEmpty, !labels.isEmpty else { return 0 }
    // "Wedding dress" and "wedding_dress" both become "wedding_dress".
    let folded = Set(labels.map { SearchTerms.terms($0).joined(separator: "_") })
    let hits = queryTerms.filter { term in
      folded.contains(term) || !(synonyms[term] ?? []).isDisjoint(with: folded)
    }
    return Double(hits.count) / Double(queryTerms.count)
  }
}
