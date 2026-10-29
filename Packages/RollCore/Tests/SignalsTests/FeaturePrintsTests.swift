import Foundation
import Testing
import Vision
@testable import Signals

struct FeaturePrintsTests {
  static let names = ["sharp_a.jpg", "sharp_b.jpg", "blurry_a.jpg", "blurry_b.jpg", "screenshot.png",
                      "dup_a.jpg", "dup_b.jpg", "unrelated.jpg"]

  @Test func nearDuplicateIsCloserThanUnrelatedAndUnderThreshold() async throws {
    let a = try await FeaturePrints.compute(try Fixtures.image("dup_a.jpg"))
    let b = try await FeaturePrints.compute(try Fixtures.image("dup_b.jpg"))
    let other = try await FeaturePrints.compute(try Fixtures.image("unrelated.jpg"))
    let near = try FeaturePrints.distance(a, b)
    let far = try FeaturePrints.distance(a, other)
    // Measured (Vision revision 2, 448-px fixtures): near-duplicate 0.049, unrelated 1.33...1.69,
    // a Gaussian-blurred copy of the same photo 0.47 (sharp_a/blurry_a) and 1.01 (sharp_b/blurry_b).
    #expect(near < 0.35)
    #expect(near < far)
    #expect(far > 1.0)
  }

  /// FP01 means revision 2: both entry points build their request from `makeRequest()`.
  @Test func requestIsPinnedToRevision2() {
    #expect(FeaturePrints.makeRequest().revision == .revision2)
    #expect(FeaturePrints.revision == .revision2)
    #expect(GenerateImageFeaturePrintRequest.supportedRevisions.contains(.revision2))
    #expect(Array(FeaturePrints.magic) == Array("FP01".utf8))
  }

  @Test func storageFormatIsMagicCountAndLittleEndianFloats() async throws {
    let image = try Fixtures.image("sharp_b.jpg")
    let data = try await FeaturePrints.compute(image)
    #expect(Array(data.prefix(4)) == Array("FP01".utf8))
    let observation = try await FeaturePrints.makeRequest().perform(on: image)
    let count = UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
    #expect(Int(count) == observation.elementCount)
    #expect(data.count == 8 + 4 * observation.elementCount)
    #expect(observation.elementType == .float)
    // The payload is the observation's own bytes.
    #expect(data.dropFirst(8) == observation.data)
  }

  @Test func decodeRoundTripsAndSelfDistanceIsZero() async throws {
    let data = try await FeaturePrints.compute(try Fixtures.image("sharp_b.jpg"))
    let print = try #require(FeaturePrints.decode(data))
    #expect(print.values.count == (data.count - 8) / 4)
    #expect(print.distance(to: print) == 0)
    #expect(try FeaturePrints.distance(data, data) == 0)
  }

  /// Our vDSP distance must be the quantity Vision's `distance(to:)` reports, for every fixture pair.
  @Test func distanceMatchesVisionForAllFixturePairs() async throws {
    var observations: [FeaturePrintObservation] = []
    var stored: [Data] = []
    for name in Self.names {
      let image = try Fixtures.image(name)
      let observation = try await FeaturePrints.makeRequest().perform(on: image)
      observations.append(observation)
      stored.append(try FeaturePrints.encode(observation))
    }
    var pairs = 0
    for i in observations.indices { for j in observations.indices where j > i {
      let vision = Float(try observations[i].distance(to: observations[j]))
      let ours = try FeaturePrints.distance(stored[i], stored[j])
      #expect(abs(ours - vision) < 1e-4, "\(Self.names[i]) vs \(Self.names[j]): ours \(ours), Vision \(vision)")
      pairs += 1
    } }
    #expect(pairs == 28)
  }

  @Test func distanceIsSymmetric() async throws {
    let a = try await FeaturePrints.compute(try Fixtures.image("sharp_a.jpg"))
    let b = try await FeaturePrints.compute(try Fixtures.image("sharp_b.jpg"))
    #expect(try FeaturePrints.distance(a, b) == FeaturePrints.distance(b, a))
  }

  @Test func malformedDataIsRejected() async throws {
    let good = try await FeaturePrints.compute(try Fixtures.image("sharp_a.jpg"))
    #expect(FeaturePrints.decode(Data()) == nil)
    #expect(FeaturePrints.decode(Data([1, 2, 3])) == nil)
    #expect(FeaturePrints.decode(good.dropLast()) == nil)                        // truncated payload
    #expect(FeaturePrints.decode(Data("XXXX".utf8) + good.dropFirst(4)) == nil)  // wrong magic
    #expect(throws: FeaturePrints.Failure.undecodable) { try FeaturePrints.distance(Data([1, 2, 3]), good) }
    #expect(throws: FeaturePrints.Failure.undecodable) { try FeaturePrints.distance(good, Data()) }
  }

  @Test func printsOfDifferentLengthAreNotComparable() throws {
    func stored(_ values: [Float]) -> Data {
      var data = Data(FeaturePrints.magic)
      withUnsafeBytes(of: UInt32(values.count).littleEndian) { data.append(contentsOf: $0) }
      for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
      return data
    }
    let two = stored([3, 4]), three = stored([1, 2, 3])
    #expect(throws: FeaturePrints.Failure.notComparable) { try FeaturePrints.distance(two, three) }
    #expect(FeaturePrints.Print(values: [1, 2]).distance(to: FeaturePrints.Print(values: [1, 2, 3])) == .infinity)
    // Squared Euclidean, like Vision: (0,0) to (3,4) is 25.
    #expect(try FeaturePrints.distance(stored([0, 0]), two) == 25)
  }
}

struct FeaturePrintsEncodeTests {
  @Test func encodeValuesRoundTripsThroughDecode() throws {
    let values: [Float] = [0, 1, -2.5, .pi, 1e-7]
    let data = FeaturePrints.encode(values: values)
    #expect(data.count == 8 + 4 * values.count)
    #expect(FeaturePrints.decode(data)?.values == values)
    #expect(try FeaturePrints.distance(data, data) == 0)
  }

  @Test func encodedEmptyPrintDoesNotDecode() {
    #expect(FeaturePrints.decode(FeaturePrints.encode(values: [])) == nil)
  }
}
