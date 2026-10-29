import Foundation
import Testing
@testable import Indexer
import Library
import Store

/// File types (UTIs) cost one resource lookup per asset, the hottest part of a first launch on a 30k library. They are
/// looked up lazily, only for photos whose type matters: ones big enough to be Squish candidates (a JPEG/PNG over 3 MB)
/// and whose size estimate depends on it. Largest first, within a limit.
struct TypeLookupTests {
  static func photo(_ id: String, w: Int, h: Int, subtypes: Int = 0, created: Double = 0) -> AssetSnapshot {
    AssetSnapshot(id: id, mediaType: MediaKind.image, subtypes: subtypes, created: created, pixelW: w, pixelH: h)
  }

  @Test func onlyPossibleSquishCandidatesLargestFirstWithinTheLimit() async throws {
    let library = FakeLibrary(assets: [
      Self.photo("small", w: 1000, h: 1000),  // 1 MP: under 3 MB even as JPEG
      Self.photo("p12", w: 4000, h: 3000), Self.photo("p48", w: 8000, h: 6000), Self.photo("p8", w: 3264, h: 2448),
      Self.photo("live", w: 4000, h: 3000, subtypes: MediaSubtype.livePhoto),  // never squished
      AssetSnapshot(id: "video", mediaType: MediaKind.video, pixelW: 3840, pixelH: 2160, duration: 10),
    ])
    library.state.withLock { $0.utiTable = ["p12": "public.jpeg", "p48": "public.heic", "p8": "public.jpeg"] }
    try await Harness.with(library: library) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      #expect(try await indexer.resolveTypes(limit: 2) == 2)
      #expect(library.state.withLock { $0.utiCalls } == [["p48", "p12"]])
      #expect(try await indexer.resolveTypes(limit: 10) == 1)
      #expect(library.state.withLock { $0.utiCalls.last } == ["p8"])
      #expect(try await indexer.resolveTypes(limit: 10) == 0, "nothing left")
      #expect(try await h.repo.asset(id: "p12")?.estBytes == 12_000_000 * 90 / 100)
      #expect(try await h.repo.asset(id: "small")?.uti == nil)
    }
  }

  @Test func aTypeTheLibraryCanNotReportIsNotAskedAgain() async throws {
    let library = FakeLibrary(assets: [Self.photo("p", w: 4000, h: 3000)])
    try await Harness.with(library: library) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      #expect(try await indexer.resolveTypes(limit: 10) == 1)
      #expect(try await indexer.resolveTypes(limit: 10) == 0)
      #expect(library.state.withLock { $0.utiCalls.count } == 1)
      #expect(try await h.repo.asset(id: "p")?.estBytes == 12_000_000 * 35 / 100, "still the default estimate")
    }
  }

  /// The floor is 3 MB at PNG's 1.6 B/px (1.875 MP), not at JPEG's 0.9 (3.33 MP): a 1.9 MP PNG is over 3 MB and must
  /// get its type to be offered by Squish. Screenshots are left out (0.40 B/px at most: never over 3 MB on an iPhone).
  @Test func photosThatCouldBeSquishPNGsAreLookedUp() async throws {
    let library = FakeLibrary(assets: [
      Self.photo("png", w: 1600, h: 1200),  // 1.92 MP
      Self.photo("small", w: 1500, h: 1200),  // 1.8 MP: under 3 MB even as PNG
      Self.photo("shot", w: 1284, h: 2778, subtypes: MediaSubtype.screenshot),
    ])
    library.state.withLock { $0.utiTable = ["png": "public.png"] }
    try await Harness.with(library: library) { h in
      let indexer = try h.indexer()
      try await indexer.sync()
      #expect(try await indexer.resolveTypes(limit: 10) == 1)
      #expect(library.state.withLock { $0.utiCalls } == [["png"]])
      #expect(try await h.repo.asset(id: "png")?.estBytes == 1_920_000 * 160 / 100)
      #expect(Indexer.typeLookupMinimumPixels == SizeEstimator.typeLookupMinimumPixels)
    }
  }
}
