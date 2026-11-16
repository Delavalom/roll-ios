import Foundation

/// `labels/<slug>.json`: what is known about one query's answers. Private (ids). Every id is in at most one list.
public struct Labels: Codable, Sendable, Equatable {
  public var relevant: [String]
  public var notRelevant: [String]
  public var unsure: [String]

  public init(relevant: [String] = [], notRelevant: [String] = [], unsure: [String] = []) {
    self.relevant = relevant; self.notRelevant = notRelevant; self.unsure = unsure
  }

  // `unsure` is optional on disk (the plan's contract has only the first two).
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    relevant = try c.decodeIfPresent([String].self, forKey: .relevant) ?? []
    notRelevant = try c.decodeIfPresent([String].self, forKey: .notRelevant) ?? []
    unsure = try c.decodeIfPresent([String].self, forKey: .unsure) ?? []
  }

  public enum Verdict: Sendable, Equatable { case relevant, notRelevant, unsure }

  /// Every id with a label.
  public var judged: Set<String> { Set(relevant).union(notRelevant).union(unsure) }

  public func verdict(_ id: String) -> Verdict? {
    if relevant.contains(id) { return .relevant }
    if notRelevant.contains(id) { return .notRelevant }
    if unsure.contains(id) { return .unsure }
    return nil
  }

  /// These labels with `verdicts` applied on top (a new verdict replaces an old one), then `alwaysRelevant` (album
  /// members: ground truth, never overridden by a judge). Lists come out sorted.
  public func merged(with verdicts: [String: Verdict], alwaysRelevant: Set<String> = []) -> Labels {
    var state: [String: Verdict] = [:]
    for id in relevant { state[id] = .relevant }
    for id in notRelevant { state[id] = .notRelevant }
    for id in unsure { state[id] = .unsure }
    for (id, v) in verdicts { state[id] = v }
    for id in alwaysRelevant { state[id] = .relevant }
    var out = Labels()
    for (id, v) in state {
      switch v {
      case .relevant: out.relevant.append(id)
      case .notRelevant: out.notRelevant.append(id)
      case .unsure: out.unsure.append(id)
      }
    }
    out.relevant.sort(); out.notRelevant.sort(); out.unsure.sort()
    return out
  }

  /// Only the ids in `ids` (e.g. those with a vector); nil keeps everything.
  public func restricted(to ids: Set<String>?) -> Labels {
    guard let ids else { return self }
    return Labels(relevant: relevant.filter(ids.contains), notRelevant: notRelevant.filter(ids.contains),
                  unsure: unsure.filter(ids.contains))
  }

  public static func load(_ dir: URL, slug: String) throws -> Labels {
    let url = dir.appending(path: "\(slug).json")
    guard FileManager.default.fileExists(atPath: url.path) else { return Labels() }
    return try JSONOut.read(Labels.self, from: url)
  }
}

/// A judge's answer for one sheet: tile numbers (1-based, as printed on the sheet). Tiles not listed are not relevant.
public struct SheetJudgment: Codable, Sendable, Equatable {
  public var relevant: [Int]
  public var unsure: [Int]

  public init(relevant: [Int] = [], unsure: [Int] = []) { self.relevant = relevant; self.unsure = unsure }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    relevant = try c.decodeIfPresent([Int].self, forKey: .relevant) ?? []
    unsure = try c.decodeIfPresent([Int].self, forKey: .unsure) ?? []
  }
}

/// Judge output: query slug → sheet name ("sheet-01", ".png" optional) → judgment.
public typealias Judgments = [String: [String: SheetJudgment]]

public enum JudgmentApplication {
  public struct Failure: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
  }

  /// Verdicts per id for one query from its judged sheets. Every tile of a judged sheet gets a verdict (listed as
  /// relevant, unsure, or else not relevant); sheets the judge didn't return stay unjudged. A tile number outside the
  /// sheet, a number listed twice, or an unknown sheet is an error, so a misread sheet can't label the wrong photos.
  public static func verdicts(manifest: SheetManifest, judged: [String: SheetJudgment]) throws -> [String: Labels.Verdict] {
    var out: [String: Labels.Verdict] = [:]
    for (rawName, judgment) in judged {
      let name = rawName.hasSuffix(".png") ? String(rawName.dropLast(4)) : rawName
      guard let sheet = manifest.sheets.first(where: { $0.file == "\(name).png" }) else {
        throw Failure("\(manifest.slug): no \(name) in the manifest")
      }
      let byNumber = Dictionary(uniqueKeysWithValues: sheet.tiles.map { ($0.n, $0.id) })
      let listed = judgment.relevant + judgment.unsure
      guard Set(listed).count == listed.count else { throw Failure("\(manifest.slug)/\(name): a tile is listed twice") }
      for n in listed where byNumber[n] == nil {
        throw Failure("\(manifest.slug)/\(name): tile \(n) isn't on the sheet (1...\(sheet.tiles.count))")
      }
      for tile in sheet.tiles {
        out[tile.id] = judgment.relevant.contains(tile.n) ? .relevant : judgment.unsure.contains(tile.n) ? .unsure : .notRelevant
      }
    }
    return out
  }
}
