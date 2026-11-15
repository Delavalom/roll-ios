import Foundation

/// A find-eval query spec: `evals/find.json` (in the repo, no private data) and private files in the same format with
/// album-derived queries (`albumKey` or `albumKeys`). Every command takes several spec files; query names must be unique across them.
///
///     {"about": "...", "templates": ["a picture of {text}"],
///      "queries": [{"name": "soccer", "text": "soccer", "group": "activity", "expect": "matches"}, ...]}
///
/// `templates` are extra query templates (`{text}` is replaced by the query text) embedded on top of the bare text and
/// `FindSpec.defaultTemplates`. A query may list its own `templates` too.
public struct FindSpec: Codable, Sendable {
  public var about: String?
  public var templates: [String]?
  public var queries: [FindQuery]
  /// Marks every query of this file private (names and texts are left out of the evidence). Album-derived queries are
  /// private anyway.
  public var `private`: Bool?

  public init(about: String? = nil, templates: [String]? = nil, queries: [FindQuery], private isPrivate: Bool? = nil) {
    self.about = about; self.templates = templates; self.queries = queries; self.private = isPrivate
  }

  /// Always embedded besides the bare text (V1's template).
  public static let defaultTemplates = ["a photo of {text}"]

  public struct Invalid: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
  }

  /// The queries of several spec files, each resolved with its file's templates. Names (and their slugs) must be
  /// unique, texts non-empty, and every template must contain `{text}`.
  public static func load(_ urls: [URL]) throws -> [ResolvedQuery] {
    guard !urls.isEmpty else { throw Invalid("no --queries spec given") }
    var out: [ResolvedQuery] = []
    for url in urls {
      let spec = try JSONDecoder().decode(FindSpec.self, from: Data(contentsOf: url))
      out += try spec.resolved()
    }
    try validateUnique(out)
    return out
  }

  /// This file's queries with their templates (defaults, then the file's, then the query's; duplicates dropped).
  public func resolved() throws -> [ResolvedQuery] {
    try queries.map { q in
      guard !q.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Invalid("a query has no name") }
      guard !q.text.trimmingCharacters(in: .whitespaces).isEmpty else { throw Invalid("\(q.name): empty text") }
      guard !q.group.isEmpty else { throw Invalid("\(q.name): no group") }
      var templates: [String] = []
      for t in Self.defaultTemplates + (self.templates ?? []) + (q.templates ?? []) where !templates.contains(t) {
        guard t.contains("{text}") else { throw Invalid("\(q.name): template \"\(t)\" has no {text}") }
        templates.append(t)
      }
      return ResolvedQuery(query: q, templates: templates, isPrivate: (self.private ?? false) || !q.allAlbumKeys.isEmpty)
    }
  }

  static func validateUnique(_ queries: [ResolvedQuery]) throws {
    var names = Set<String>(), slugs = Set<String>()
    for q in queries {
      guard names.insert(q.name).inserted else { throw Invalid("duplicate query name \(q.name)") }
      guard slugs.insert(q.slug).inserted else { throw Invalid("two queries share the slug \(q.slug)") }
    }
  }
}

public struct FindQuery: Codable, Sendable, Equatable {
  public var name: String
  /// What the person types.
  public var text: String
  /// activity / event / place-trip / thing / dated / nonsense / album: the means in `score` are per group.
  public var group: String
  public var expect: FindExpectation
  /// For album-derived queries (private specs): the album's key in the export's `albums`; its members are relevant.
  public var albumKey: String?
  /// Several albums: the union of their members is relevant. Combined with `albumKey` when both are given.
  public var albumKeys: [String]?
  /// Extra templates for this query only.
  public var templates: [String]?

  public init(name: String, text: String, group: String, expect: FindExpectation, albumKey: String? = nil,
              albumKeys: [String]? = nil, templates: [String]? = nil) {
    self.name = name; self.text = text; self.group = group; self.expect = expect; self.albumKey = albumKey
    self.albumKeys = albumKeys; self.templates = templates
  }

  /// `albumKey` and `albumKeys` together, each once; empty for a query without albums.
  public var allAlbumKeys: [String] {
    var out: [String] = []
    for k in [albumKey].compactMap({ $0 }) + (albumKeys ?? []) where !out.contains(k) { out.append(k) }
    return out
  }
}

public enum FindExpectation: String, Codable, Sendable {
  /// Something in the library answers it.
  case matches
  /// Nonsense or absent: an honest search finds nothing (no strong matches).
  case nothing
}

/// A query with everything resolved: its slug and the texts to embed.
public struct ResolvedQuery: Sendable, Equatable {
  public var query: FindQuery
  /// Templates with `{text}`, the defaults first.
  public var templates: [String]
  /// Leave the name and text out of the evidence (album-derived or from a private spec).
  public var isPrivate: Bool

  public init(query: FindQuery, templates: [String], isPrivate: Bool) {
    self.query = query; self.templates = templates; self.isPrivate = isPrivate
  }

  public var name: String { query.name }
  public var text: String { query.text }
  public var slug: String { Slug.make(query.name) }

  /// The bare text, then each template applied (duplicates dropped). Every one is embedded and keyed by this exact text.
  public var texts: [String] {
    var out = [query.text]
    for t in templates {
      let applied = Self.apply(t, to: query.text)
      if !out.contains(applied) { out.append(applied) }
    }
    return out
  }

  public static func apply(_ template: String, to text: String) -> String {
    template.replacingOccurrences(of: "{text}", with: text)
  }
}

public enum Slug {
  /// "Birthday cake (candles)" → "birthday-cake-candles"; the same rule as pile-eval's.
  public static func make(_ name: String) -> String {
    name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
  }
}
