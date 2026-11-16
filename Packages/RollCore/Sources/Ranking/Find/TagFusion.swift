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

  /// A label as the synonym table writes it: "Wedding dress" and "wedding_dress" both become "wedding_dress".
  public static func fold(_ label: String) -> String {
    SearchTerms.terms(label).joined(separator: "_")
  }

  /// Share of `queryTerms` (folded content words, `SearchTerms.queryTerms`) for which some label equals the word or is
  /// one of its synonyms. 0 for no terms or no labels.
  public static func coverage(queryTerms: [String], labels: [String],
                              synonyms: [String: Set<String>] = defaultSynonyms) -> Double {
    guard !queryTerms.isEmpty, !labels.isEmpty else { return 0 }
    let folded = Set(labels.map(fold))
    let hits = queryTerms.filter { term in
      folded.contains(term) || !(synonyms[term] ?? []).isDisjoint(with: folded)
    }
    return Double(hits.count) / Double(queryTerms.count)
  }
}

/// Every photo's tags folded once (V4), as an inverted index: folded label → photos. Built when tags are loaded (the
/// engine, once per tag write; the eval, once per library), so a query costs one lookup per query word and synonym
/// instead of folding every photo's labels again (`TagFusion.coverage` per photo took ~1.4 s a query over 30k photos).
public struct TagIndex: Sendable, Equatable {
  /// Photo ids, by position.
  private var ids: [String] = []
  /// Folded label → positions in `ids` of the photos carrying it (each once).
  private var postings: [String: [Int32]] = [:]

  public static let empty = TagIndex()

  public init() {}

  /// `labels`: photo id → its labels, as `TagFusion.coverage` takes them.
  public init(labels: [String: [String]]) {
    ids.reserveCapacity(labels.count)
    for (id, list) in labels {
      var seen = Set<String>()
      let at = Int32(ids.count)
      for label in list {
        let folded = TagFusion.fold(label)
        guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
        postings[folded, default: []].append(at)
      }
      if !seen.isEmpty { ids.append(id) }
    }
  }

  /// Photos with at least one tag.
  public var photoCount: Int { ids.count }
  public var isEmpty: Bool { ids.isEmpty }

  /// Photo id → `TagFusion.coverage(queryTerms:labels:synonyms:)`, for the photos whose coverage is above 0.
  public func coverage(queryTerms: [String], synonyms: [String: Set<String>] = TagFusion.defaultSynonyms)
    -> [String: Double] {
    guard !queryTerms.isEmpty, !postings.isEmpty else { return [:] }
    var hits = [UInt16](repeating: 0, count: ids.count)
    var lastTerm = [Int32](repeating: -1, count: ids.count)  // a photo counts once per term
    var touched: [Int32] = []
    for (t, term) in queryTerms.enumerated() {
      for label in (synonyms[term] ?? []).union([term]) {
        guard let list = postings[label] else { continue }
        for p in list where lastTerm[Int(p)] != Int32(t) {
          lastTerm[Int(p)] = Int32(t)
          if hits[Int(p)] == 0 { touched.append(p) }
          hits[Int(p)] &+= 1
        }
      }
    }
    let n = Double(queryTerms.count)
    var out: [String: Double] = [:]
    out.reserveCapacity(touched.count)
    for p in touched { out[ids[Int(p)]] = Double(hits[Int(p)]) / n }
    return out
  }
}
