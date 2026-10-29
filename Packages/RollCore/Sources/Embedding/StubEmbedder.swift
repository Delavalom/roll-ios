import CoreGraphics
import Foundation

/// Deterministic fake embedder. No model, no I/O.
///
/// Images: a 16x16 grayscale downsample, shifted to [-0.5, 0.5], projected through a seeded
/// random matrix, then normalized. Queries: the sum of one seeded random vector per lowercased
/// word, then normalized. Similar images and queries sharing words therefore land near each other.
///
/// The query path is pure integer hashing plus float math and is pinned by a test. The image path
/// goes through CoreGraphics' downsampling, so it is deterministic per OS build, not across OS
/// versions: never persist stub image vectors across an OS update. Bump "stub-vN" in `revision`
/// whenever either path changes. Tests and previews only; never a fallback for the real model.
public struct StubEmbedder: Embedder {
  public let dimensions: Int
  public let revision: String
  private let seed: UInt64

  public init(dimensions: Int = 256, seed: UInt64 = 7) {
    self.dimensions = dimensions
    self.seed = seed
    self.revision = "stub-v1-\(seed)-\(dimensions)"
  }

  public func embed(image: CGImage) async throws -> [Float] {
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return fallback(key: 0) }

    var out = [Float](repeating: 0, count: dimensions)
    for (j, p) in pixels.enumerated() {
      let x = Float(p) / 255 - 0.5
      guard x != 0 else { continue }
      let rowSeed = Self.mix(seed &+ UInt64(j) &* 0x9E37_79B9_7F4A_7C15)
      var rng = SplitMix64(state: rowSeed)
      for i in 0..<dimensions { out[i] += x * rng.nextSigned() }
    }
    return normalized(out, key: UInt64(pixels.reduce(0) { Int($0) &+ Int($1) }))
  }

  public func embed(query: String) async throws -> [Float] {
    let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    var out = [Float](repeating: 0, count: dimensions)
    for word in words {
      var rng = SplitMix64(state: Self.mix(seed ^ Self.fnv1a(word)))
      for i in 0..<dimensions { out[i] += rng.nextSigned() }
    }
    return normalized(out, key: 1)
  }

  // MARK: - helpers

  private func normalized(_ v: [Float], key: UInt64) -> [Float] {
    let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    guard n > 1e-9 else { return fallback(key: key) }
    return v.map { $0 / n }
  }

  /// A fixed unit vector for degenerate input (empty query, undrawable image).
  private func fallback(key: UInt64) -> [Float] {
    var rng = SplitMix64(state: Self.mix(seed ^ 0xFA11_BAC4 ^ key))
    let v = (0..<dimensions).map { _ in rng.nextSigned() }
    let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / n }
  }

  private static func mix(_ x: UInt64) -> UInt64 {
    var rng = SplitMix64(state: x)
    return rng.next()
  }

  private static func fnv1a<S: Sequence>(_ s: S) -> UInt64 where S.Element == Character {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in String(s).utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
  }
}

struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  /// Uniform in [-1, 1).
  mutating func nextSigned() -> Float {
    Float(next() >> 40) / Float(1 << 23) - 1
  }
}
