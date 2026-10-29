import CoreGraphics
import Foundation
import Testing
@testable import Embedding

/// Builds a w x h grayscale CGImage from a per-pixel function.
func makeImage(width: Int = 64, height: Int = 64, _ pixel: (Int, Int) -> UInt8) -> CGImage {
  var bytes = [UInt8](repeating: 0, count: width * height)
  for y in 0..<height { for x in 0..<width { bytes[y * width + x] = pixel(x, y) } }
  let provider = CGDataProvider(data: Data(bytes) as CFData)!
  return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
func norm(_ a: [Float]) -> Float { cosine(a, a).squareRoot() }

struct StubEmbedderTests {
  let stub = StubEmbedder()
  let gradient = makeImage { x, _ in UInt8(x * 4) }
  let checker = makeImage { x, y in ((x / 8 + y / 8) % 2 == 0) ? 255 : 0 }

  @Test func reportsDimensionsAndRevision() {
    #expect(stub.dimensions == 256)
    #expect(stub.revision == "stub-v1-7-256")
    #expect(StubEmbedder(dimensions: 32, seed: 3).revision == "stub-v1-3-32")
    #expect(StubEmbedder(dimensions: 32).dimensions == 32)
  }

  @Test func identicalImageGivesIdenticalVector() async throws {
    let a = try await stub.embed(image: gradient)
    let b = try await stub.embed(image: gradient)
    #expect(a == b)
    #expect(a.count == 256)
  }

  @Test func imageVectorIsNormalized() async throws {
    let v = try await stub.embed(image: checker)
    #expect(abs(norm(v) - 1) < 1e-4)
  }

  @Test func differentImagesAreNotNearlyIdentical() async throws {
    let a = try await stub.embed(image: gradient)
    let b = try await stub.embed(image: checker)
    #expect(cosine(a, b) < 0.99)
  }

  @Test func uniformImagesStillGetAUnitVector() async throws {
    let v = try await stub.embed(image: makeImage { _, _ in 128 })
    #expect(abs(norm(v) - 1) < 1e-4)
  }

  @Test func identicalQueryGivesIdenticalNormalizedVector() async throws {
    let a = try await stub.embed(query: "a screenshot of a phone")
    let b = try await stub.embed(query: "a screenshot of a phone")
    #expect(a == b)
    #expect(abs(norm(a) - 1) < 1e-4)
  }

  @Test func queryIgnoresCaseAndPunctuation() async throws {
    let a = try await stub.embed(query: "Meme, with Caption!")
    let b = try await stub.embed(query: "meme with caption")
    #expect(a == b)
  }

  @Test func queriesSharingWordsAreCloserThanUnrelatedOnes() async throws {
    let a = try await stub.embed(query: "a blurry photo")
    let b = try await stub.embed(query: "a blurry picture")
    let c = try await stub.embed(query: "tax receipt scan")
    #expect(cosine(a, b) > cosine(a, c))
  }

  @Test func emptyQueryStillGetsAUnitVector() async throws {
    let v = try await stub.embed(query: "   ")
    #expect(abs(norm(v) - 1) < 1e-4)
  }

  @Test func seedChangesTheProjection() async throws {
    let a = try await StubEmbedder(seed: 1).embed(query: "meme")
    let b = try await StubEmbedder(seed: 2).embed(query: "meme")
    #expect(a != b)
  }

  /// Pins the query path so an accidental change to hashing or projection (which would silently
  /// invalidate stored stub vectors) fails loudly. Bump the "stub-vN" revision if this must change.
  @Test func queryPathOutputIsPinned() async throws {
    let v = try await stub.embed(query: "meme")
    let expected: [Float] = [0.045997413, 0.085533419, -0.060884889]
    for (got, want) in zip(v.prefix(3), expected) { #expect(abs(got - want) < 1e-6, "got \(got), want \(want)") }
    let w = try await StubEmbedder(dimensions: 8, seed: 1).embed(query: "a blurry photo")
    let expectedW: [Float] = [-0.140569215, -0.516726530, -0.634057073]
    for (got, want) in zip(w.prefix(3), expectedW) { #expect(abs(got - want) < 1e-6, "got \(got), want \(want)") }
  }
}
