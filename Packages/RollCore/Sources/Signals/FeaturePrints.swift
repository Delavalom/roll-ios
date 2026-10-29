import Accelerate
import CoreGraphics
import Foundation
import Vision

/// Vision image feature prints for near-duplicate detection.
///
/// **Storage format** (`Data`, 8 + 4n bytes): the magic `"FP01"`, the element count n as a
/// little-endian `UInt32`, then n little-endian `Float32` values copied from
/// `FeaturePrintObservation.data` (only `.float` element type is accepted). Raw floats decode in
/// microseconds and compare with one vDSP call, and the layout does not depend on Foundation's
/// Codable encoding.
///
/// **`FP01` means Vision feature-print revision 2** (`GenerateImageFeaturePrintRequest.Revision.revision2`).
/// Both the standalone request and `VisionBatch` build their request with `makeRequest()`, which pins
/// that revision, so an OS update that makes a newer revision the default cannot silently mix vectors
/// from two embeddings in one library. Adopting a new revision means a new magic (`FP02`), a re-index
/// of stored prints, and a new differential test.
///
/// **Distance** is the same quantity as `FeaturePrintObservation.distance(to:)`: the *squared*
/// Euclidean distance (measured: Vision's value equals the square of the L2 norm of the difference),
/// verified for every fixture pair by the differential test in `FeaturePrintsTests` (tolerance 1e-4).
/// Prints of different length are not comparable (`Float.infinity`; `distance(_:_:)` throws).
public enum FeaturePrints {
  public enum Failure: Error, Equatable {
    case undecodable
    case unsupportedElementType
    case notComparable
  }

  /// A decoded print, ready for repeated comparisons (decode once, compare many times).
  public struct Print: Sendable, Equatable {
    public let values: [Float]
    public init(values: [Float]) { self.values = values }

    /// `Float.infinity` when the two prints have different lengths.
    public func distance(to other: Print) -> Float {
      guard values.count == other.values.count, !values.isEmpty else { return .infinity }
      return vDSP.distanceSquared(values, other.values)
    }
  }

  static let magic: [UInt8] = Array("FP01".utf8)
  private static let headerSize = 8

  /// The revision `FP01` data is produced with.
  static let revision = GenerateImageFeaturePrintRequest.Revision.revision2

  static func makeRequest() -> GenerateImageFeaturePrintRequest {
    GenerateImageFeaturePrintRequest(revision)
  }

  public static func compute(_ image: CGImage) async throws -> Data {
    let observation = try await makeRequest().perform(on: image)
    return try encode(observation)
  }

  /// Distance between two stored prints (0 = identical; under about 0.35 for near-duplicates).
  public static func distance(_ a: Data, _ b: Data) throws -> Float {
    guard let first = decode(a), let second = decode(b) else { throw Failure.undecodable }
    guard first.values.count == second.values.count else { throw Failure.notComparable }
    return first.distance(to: second)
  }

  /// Decodes stored bytes; nil when the magic, length or size does not match.
  public static func decode(_ data: Data) -> Print? {
    guard data.count >= headerSize, data.prefix(4).elementsEqual(magic) else { return nil }
    let bytes = [UInt8](data)
    let count = Int(UInt32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }))
    guard count > 0, bytes.count == headerSize + count * 4 else { return nil }
    var values = [Float](repeating: 0, count: count)
    bytes.withUnsafeBytes { raw in
      for i in 0..<count {
        let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: headerSize + i * 4, as: UInt32.self))
        values[i] = Float(bitPattern: bits)
      }
    }
    return Print(values: values)
  }

  /// Stores raw values in the `FP01` layout (the inverse of `decode`). For fixtures and previews; the Indexer
  /// stores what Vision computed.
  public static func encode(values: [Float]) -> Data {
    var out = Data(magic)
    withUnsafeBytes(of: UInt32(values.count).littleEndian) { out.append(contentsOf: $0) }
    for value in values {
      withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) }
    }
    return out
  }

  static func encode(_ observation: FeaturePrintObservation) throws -> Data {
    guard observation.elementType == .float else { throw Failure.unsupportedElementType }
    let count = observation.elementCount
    guard count > 0, observation.data.count == count * 4 else { throw Failure.undecodable }
    var out = Data(magic)
    withUnsafeBytes(of: UInt32(count).littleEndian) { out.append(contentsOf: $0) }
    // `observation.data` is host-endian Float32; every Apple platform is little-endian, but go through
    // bit patterns so the stored bytes are little-endian by construction.
    observation.data.withUnsafeBytes { raw in
      for i in 0..<count {
        let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
        withUnsafeBytes(of: bits.littleEndian) { out.append(contentsOf: $0) }
      }
    }
    return out
  }
}
