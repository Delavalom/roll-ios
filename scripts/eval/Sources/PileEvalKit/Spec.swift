import Foundation

/// `evals/piles.json`: queries and the metadata rules that label their expected matches (proxy labels: no ids, no
/// hand-labelling; see `docs/investigations/2026-10-29-pile-eval.md` for what they can and can't say).
public struct PileSpec: Codable, Sendable {
  public var about: String
  /// Rule name → label rule.
  public var rules: [String: Rule]
  public var queries: [PileQuery]

  public init(about: String, rules: [String: Rule], queries: [PileQuery]) {
    self.about = about; self.rules = rules; self.queries = queries
  }

  public struct Invalid: Error, CustomStringConvertible {
    public var description: String
    public init(description: String) { self.description = description }
  }

  /// Each query has exactly one of `text` / `preset`, and a `rule` that exists when it expects matches.
  public func validated() throws -> PileSpec {
    var names = Set<String>()
    for q in queries {
      guard names.insert(q.name).inserted else { throw Invalid(description: "duplicate query \(q.name)") }
      guard (q.text == nil) != (q.preset == nil) else {
        throw Invalid(description: "\(q.name): give exactly one of text and preset")
      }
      if let rule = q.rule, rules[rule] == nil { throw Invalid(description: "\(q.name): unknown rule \(rule)") }
      if q.expect == .matches, q.rule == nil { throw Invalid(description: "\(q.name): expects matches but has no rule") }
    }
    return self
  }
}

/// A label rule: a SQL condition over Roll's `asset` table (live rows only), e.g. `(subtypes & 4) != 0`.
public struct Rule: Codable, Sendable {
  public var sql: String
  public var about: String
  /// Whether the label shows in the pixels the vector was made from. A Live Photo or a video looks like any other
  /// frame: those rules are controls, expected near chance.
  public var visible: Bool

  public init(sql: String, about: String, visible: Bool) {
    self.sql = sql; self.about = about; self.visible = visible
  }
}

public struct PileQuery: Codable, Sendable {
  public var name: String
  /// A typed query (embedded with the query prefix, like `SwipefileEngine`'s prompts).
  public var text: String?
  /// A built-in pile (`Preset` raw value): its prompts, best prompt per vector.
  public var preset: String?
  public var rule: String?
  public var expect: Expectation

  public init(name: String, text: String?, preset: String?, rule: String?, expect: Expectation) {
    self.name = name; self.text = text; self.preset = preset; self.rule = rule; self.expect = expect
  }
}

public enum Expectation: String, Codable, Sendable {
  /// The rule's assets are the right answers.
  case matches
  /// Nonsense: an honest search finds nothing.
  case nothing
  /// No proxy label: only how many results pass each gate.
  case unlabelled
}
