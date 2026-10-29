import Foundation
@testable import Store

enum Fixtures {
  static func asset(_ id: String, created: Double? = nil, embedded: Bool = false, signalsDone: Bool = false,
                    estBytes: Int64 = 1000, mediaType: Int = 1) -> AssetRecord {
    AssetRecord(id: id, mediaType: mediaType, subtypes: 0, created: created, pixelW: 4000, pixelH: 3000, duration: nil,
                isFavorite: false, burstId: nil, uti: "public.heic", estBytes: estBytes, cloudOnly: false,
                embedded: embedded, signalsDone: signalsDone, blur: nil, aesthetic: nil, isUtility: nil,
                sensitive: nil, phash: nil, featurePrint: nil, deleted: false)
  }

  static func swipefile(_ id: String = "sf1") -> SwipefileRecord {
    SwipefileRecord(id: id, name: "Memes", kind: .custom, preset: nil, prompts: ["a meme", "reaction image"],
                    examples: [], action: .delete, albumName: nil, classifier: nil, swipesSinceTrain: 0, created: 100)
  }

  /// A fresh temp directory, deleted when `body` returns or throws.
  static func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("roll-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
  }

  /// A unit vector with a 1 at `axis`.
  static func unit(_ axis: Int, dims: Int = 8) -> [Float] {
    var v = [Float](repeating: 0, count: dims)
    v[axis] = 1
    return v
  }
}
