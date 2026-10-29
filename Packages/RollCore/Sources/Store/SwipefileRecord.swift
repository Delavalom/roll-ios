import Foundation
import GRDB

public enum SwipefileKind: String, Codable, Sendable, DatabaseValueConvertible {
  case preset, custom
}

public enum SwipefileAction: String, Codable, Sendable, DatabaseValueConvertible {
  case delete, album, squish
}

public struct SwipefileRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "swipefile"

  /// The embedding size Roll ships with.
  public static let defaultDimensions = 256

  /// Classifier blob layout: `dimensions` weights followed by the bias, little-endian Float32.
  public static func classifierLength(dimensions: Int) -> Int { dimensions + 1 }

  public var id: String
  public var name: String
  public var kind: SwipefileKind
  public var preset: String?
  /// Stored as JSON text.
  public var prompts: [String]
  /// Positive example asset ids, stored as JSON text.
  public var examples: [String]
  public var action: SwipefileAction
  public var albumName: String?
  public var classifier: Data?
  /// The embedder (vector index) revision `classifier` was trained on. A classifier whose revision
  /// differs from the current index's is ignored: its weights live in another vector space.
  public var classifierRevision: String?
  public var swipesSinceTrain: Int
  public var created: Double

  public init(id: String, name: String, kind: SwipefileKind, preset: String? = nil, prompts: [String], examples: [String] = [],
              action: SwipefileAction, albumName: String? = nil, classifier: Data? = nil, classifierRevision: String? = nil,
              swipesSinceTrain: Int = 0, created: Double) {
    self.id = id; self.name = name; self.kind = kind; self.preset = preset; self.prompts = prompts
    self.examples = examples; self.action = action; self.albumName = albumName; self.classifier = classifier
    self.classifierRevision = classifierRevision
    self.swipesSinceTrain = swipesSinceTrain; self.created = created
  }

  public static func encodeClassifier(_ values: [Float]) -> Data {
    var data = Data(capacity: values.count * 4)
    for v in values {
      withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  /// nil unless `data` holds exactly `dimensions + 1` floats.
  public static func decodeClassifier(_ data: Data, dimensions: Int = defaultDimensions) -> [Float]? {
    let length = classifierLength(dimensions: dimensions)
    guard dimensions > 0, data.count == length * 4 else { return nil }
    return data.withUnsafeBytes { raw in
      (0..<length).map { i in
        Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
      }
    }
  }
}
