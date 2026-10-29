import CryptoKit
import Foundation

/// `manifest.json` of a published revision: which archive to download, its size and SHA-256.
///
/// ```json
/// {"format": 1, "archive": "EmbeddingGemma2.aar", "size": 366000000, "sha256": "<64 hex>",
///  "unpacked_size": 485000000, "revision": "v1.0.0", "functions": ["embed_text_16", ...]}
/// ```
/// `unpacked_size`, `revision` and `functions` are optional and unknown keys are ignored, so the publisher can add
/// fields. The archive must be a single file name next to `manifest.json`, other than the names Roll uses in the same
/// folder. `size` and `unpacked_size` are positive and at most `maxBytes`, so the space arithmetic can't overflow.
public struct ModelManifest: Sendable, Equatable {
  public static let fileName = "manifest.json"
  public static let supportedFormat = 1
  /// 4 GiB: far above the model (about 359 MB packed); a larger size is a bad manifest, not a model.
  public static let maxBytes: Int64 = 4 << 30
  /// The functions Roll loads: the four text lengths and the five image buckets of both budgets (embeddinggemma-coreml
  /// `egcm/functions.py`; `EmbeddingGemma.textFunctions` and `imageFunctions(budget:)` in the package).
  public static let requiredFunctions: Set<String> = Set(
    [16, 32, 64, 128].map { "embed_text_\($0)" }
      + [70, 280].flatMap { b in ["tall", "portrait", "square", "landscape", "wide"].map { "embed_image_\(b)_\($0)" } })
  /// What the archive must contain at its root (what `EmbeddingGemma.load(.installed(_:repo:revision:))` requires).
  public static let requiredFiles = ["EmbeddingGemma2.mlpackage/Manifest.json", "tokenizer/tokenizer.json",
                                     "tokenizer/tokenizer_config.json"]

  public let archive: String
  /// Bytes of the archive: what the download costs.
  public let size: Int64
  public let sha256: String
  /// Bytes once extracted, if the publisher says.
  public let unpackedSize: Int64?
  /// The publisher's label for the model (for logs; the Hub commit identifies it).
  public let label: String?
  public let functions: [String]?

  public init(archive: String, size: Int64, sha256: String, unpackedSize: Int64? = nil, label: String? = nil,
              functions: [String]? = nil) {
    self.archive = archive
    self.size = size
    self.sha256 = sha256
    self.unpackedSize = unpackedSize
    self.label = label
    self.functions = functions
  }

  private struct Wire: Decodable {
    let format: Int?
    let archive: String
    let size: Int64
    let sha256: String
    let unpacked_size: Int64?
    let revision: String?
    let functions: [String]?
  }

  public static func decode(_ data: Data) throws -> ModelManifest {
    let w: Wire
    do { w = try JSONDecoder().decode(Wire.self, from: data) } catch {
      throw ModelInstallError.invalidManifest("not an object with archive, size and sha256")
    }
    guard (w.format ?? supportedFormat) == supportedFormat else {
      throw ModelInstallError.invalidManifest("format \(w.format ?? 0) is newer than this app")
    }
    guard isPlainName(w.archive) else { throw ModelInstallError.invalidManifest("unsafe archive name \(w.archive)") }
    guard (1...maxBytes).contains(w.size), w.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
      throw ModelInstallError.invalidManifest("bad size or sha256")
    }
    if let unpacked = w.unpacked_size, !(1...maxBytes).contains(unpacked) {
      throw ModelInstallError.invalidManifest("bad unpacked_size \(unpacked)")
    }
    if let fns = w.functions {
      let missing = requiredFunctions.subtracting(fns)
      guard missing.isEmpty else {
        throw ModelInstallError.invalidManifest("missing functions \(missing.sorted().joined(separator: ", "))")
      }
    }
    return ModelManifest(archive: w.archive, size: w.size, sha256: w.sha256, unpackedSize: w.unpacked_size,
                         label: w.revision, functions: w.functions)
  }

  /// One plain file-name component: not empty, no "/", not "." or "..", not hidden, no temporary-file suffix, and
  /// none of the names Roll keeps next to it in `<revision>.partial/` (`manifest.json`, `unpacked`).
  static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name != ".."
      && !name.hasSuffix(".download") && !name.hasSuffix(".resume")
      && name.lowercased() != fileName && name.lowercased() != ModelFolders.unpackedName
  }
}

public enum Checksum {
  /// Lowercase hex SHA-256 of a file, streamed in 1 MB chunks (each read drained in its own autorelease pool, so a
  /// 359 MB archive doesn't pile up bridged buffers).
  public static func sha256(file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while try autoreleasepool(invoking: { () throws -> Bool in
      guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
      hasher.update(data: chunk)
      return true
    }) {}
    return hex(hasher.finalize())
  }

  public static func sha256(data: Data) -> String { hex(SHA256.hash(data: data)) }

  /// True if `file` has `size` bytes and that SHA-256 (the size first, so a short file isn't hashed).
  public static func verifies(_ file: URL, size: Int64, sha256 expected: String) -> Bool {
    guard let actual = fileSize(file), actual == size else { return false }
    return (try? sha256(file: file)) == expected
  }

  static func fileSize(_ file: URL) -> Int64? {
    (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
  }

  private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
