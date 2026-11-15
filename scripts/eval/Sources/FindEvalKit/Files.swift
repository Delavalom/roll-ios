import Foundation

/// `find-eval embed`'s output: unit query vectors keyed by the exact text embedded, with the model revision they must
/// match (the index refuses any other). The same shape as pile-eval's query vectors.
public struct QueryVectorsFile: Codable, Sendable {
  public var revision: String
  public var dimensions: Int
  public var vectors: [String: [Float]]

  public init(revision: String, dimensions: Int, vectors: [String: [Float]]) {
    self.revision = revision; self.dimensions = dimensions; self.vectors = vectors
  }
}

/// One line of the phone export's `assets.jsonl` (plan, "Data contracts"). Private: ids, dates, coordinates.
public struct ExportAsset: Codable, Sendable, Equatable {
  public var id: String
  public var created: Double?
  public var lat: Double?
  public var lon: Double?
  public var hacc: Double?
  public var mediaType: Int?
  public var subtypes: Int?
  public var albums: [String]?

  public init(id: String, created: Double? = nil, lat: Double? = nil, lon: Double? = nil, hacc: Double? = nil,
              mediaType: Int? = nil, subtypes: Int? = nil, albums: [String]? = nil) {
    self.id = id; self.created = created; self.lat = lat; self.lon = lon; self.hacc = hacc
    self.mediaType = mediaType; self.subtypes = subtypes; self.albums = albums
  }
}

/// One line of `vision.jsonl`: Vision's scene labels (identifier, confidence), or `missing`.
public struct VisionLine: Sendable, Equatable {
  public var id: String
  public var labels: [(identifier: String, confidence: Double)]
  public var missing: Bool

  public static func == (a: VisionLine, b: VisionLine) -> Bool {
    a.id == b.id && a.missing == b.missing && a.labels.map(\.identifier) == b.labels.map(\.identifier)
      && a.labels.map(\.confidence) == b.labels.map(\.confidence)
  }
}

public enum JSONLines {
  /// Each non-empty line decoded as `T`; a line that doesn't decode is an error (with its number, not its content).
  public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var out: [T] = []
    let decoder = JSONDecoder()
    for (n, line) in text.split(whereSeparator: \.isNewline).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      do { out.append(try decoder.decode(T.self, from: Data(trimmed.utf8))) } catch {
        throw FindSpec.Invalid("\(url.lastPathComponent): line \(n + 1) doesn't decode")
      }
    }
    return out
  }

  /// `vision.jsonl`: `{"id","labels":[["identifier",confidence]]}` or `{"id","missing":true}`.
  public static func vision(from url: URL) throws -> [VisionLine] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var out: [VisionLine] = []
    for line in text.split(whereSeparator: \.isNewline) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let id = object["id"] as? String else { continue }
      let pairs = (object["labels"] as? [[Any]] ?? []).compactMap { pair -> (String, Double)? in
        guard pair.count == 2, let name = pair[0] as? String, let c = (pair[1] as? NSNumber)?.doubleValue else { return nil }
        return (name, c)
      }
      out.append(VisionLine(id: id, labels: pairs, missing: object["missing"] as? Bool ?? false))
    }
    return out
  }
}

public enum Albums {
  /// Album key → member ids, from the export.
  public static func members(_ assets: [ExportAsset]) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    for a in assets { for key in a.albums ?? [] { out[key, default: []].insert(a.id) } }
    return out
  }

  /// One query's album members: the union over `keys`, split into those with a vector in the index (`indexed`; nil
  /// means unknown, so all count) and those without (newer than the index copy: they can't be found, so they are left
  /// out of the labels and reported apart). Throws when a key isn't in the export.
  public static func split(keys: [String], members: [String: Set<String>],
                           indexed: Set<String>?) throws -> (withVector: Set<String>, withoutVector: Int) {
    var all = Set<String>()
    for key in keys {
      guard let m = members[key] else { throw FindSpec.Invalid("an album key of a query isn't in the export") }
      all.formUnion(m)
    }
    guard let indexed else { return (all, 0) }
    let kept = all.intersection(indexed)
    return (kept, all.count - kept.count)
  }
}

/// `<pool root>/indexed-ids.txt` (written by `pool`, private): every id with a vector in the index, so the commands
/// that don't read the index count only assets a search could return.
public enum IndexedIds {
  public static func url(_ poolRoot: URL) -> URL { poolRoot.appending(path: "indexed-ids.txt") }

  public static func write(_ ids: [String], poolRoot: URL) throws {
    try FileManager.default.createDirectory(at: poolRoot, withIntermediateDirectories: true)
    try (ids.sorted().joined(separator: "\n") + "\n").write(to: url(poolRoot), atomically: true, encoding: .utf8)
  }

  /// Nil when the file isn't there.
  public static func read(_ poolRoot: URL) throws -> Set<String>? {
    let u = url(poolRoot)
    guard FileManager.default.fileExists(atPath: u.path) else { return nil }
    return Set(try String(contentsOf: u, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init))
  }
}

/// JSON writing shared by the commands.
public enum JSONOut {
  /// Sorted keys, pretty-printed, doubles rounded to 4 decimals (evidence files stay small and diffable).
  public static func write(_ value: some Encodable, to url: URL) throws {
    let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    let data = try JSONSerialization.data(withJSONObject: round(raw), options: [.sortedKeys, .prettyPrinted,
                                                                                .withoutEscapingSlashes])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  static func round(_ any: Any) -> Any {
    if let d = any as? [String: Any] { return d.mapValues(round) }
    if let a = any as? [Any] { return a.map(round) }
    if let x = any as? NSNumber, CFNumberIsFloatType(x) {
      // Via the shortest decimal text, so 0.4 is written as 0.4, not 0.40000000000000002.
      return NSDecimalNumber(string: "\((x.doubleValue * 10_000).rounded() / 10_000)")
    }
    return any
  }

  public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
  }
}
