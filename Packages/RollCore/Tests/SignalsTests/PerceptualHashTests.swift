import Testing
@testable import Signals

/// Re-measured with the shared 256-px bitmap + vImage scale (2026-10-23): near-duplicate pair 2 bits;
/// a blurred copy of its own original 3 (sharp_a/blurry_a) and 0 (sharp_b/blurry_b), so dHash does not
/// tell blur from sharp; unrelated pairs 24...37 bits.
struct PerceptualHashTests {
  @Test func nearDuplicatesAreWithinTenBits() throws {
    let a = try #require(PerceptualHash.dHash(try Fixtures.image("dup_a.jpg")))
    let b = try #require(PerceptualHash.dHash(try Fixtures.image("dup_b.jpg")))
    #expect(PerceptualHash.hamming(a, b) <= 10)  // measured 2
  }

  @Test func unrelatedImagesAreAtLeastTwentyBitsApart() throws {
    let names = ["sharp_a.jpg", "sharp_b.jpg", "dup_a.jpg", "unrelated.jpg", "screenshot.png"]
    let hashes = try names.map { try #require(PerceptualHash.dHash(try Fixtures.image($0))) }
    for i in hashes.indices { for j in hashes.indices where j > i {
      #expect(PerceptualHash.hamming(hashes[i], hashes[j]) >= 20, "\(names[i]) vs \(names[j])")  // measured min 24
    } }
  }

  @Test func hashIsDeterministicAndFlatImagesHashToZero() throws {
    let image = try Fixtures.image("sharp_a.jpg")
    #expect(PerceptualHash.dHash(image) == PerceptualHash.dHash(image))
    #expect(PerceptualHash.dHash(Fixtures.solid(width: 64, height: 64, gray: 200)) == 0)
  }

  @Test func hammingCountsDifferingBits() {
    #expect(PerceptualHash.hamming(0, 0) == 0)
    #expect(PerceptualHash.hamming(0b1010, 0b0110) == 2)
    #expect(PerceptualHash.hamming(.max, 0) == 64)
  }
}
