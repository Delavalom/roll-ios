import Foundation

/// Refuses a whole query ("Nothing found for …") from statistics of its meaning scores over the library, before any
/// photo is cut. Every threshold is nil (unused) by default, so the default test never refuses.
///
/// Words rescue a query: if any photo holds `FindConfig.coverageGate` of its words (or its tags qualify it), it is
/// never refused; nor is a date- or place-only query.
public struct NothingFoundTest: Sendable, Equatable, Codable {
  /// Refuse when the best meaning z (combined over query texts and seed-blended, before the event bonus) is under this.
  public var minTopZ: Float? = nil
  /// Refuse when the best cosine of the first query text over the library is under this. In the pile eval this
  /// separated nonsense by < 0.01, so it is unlikely to work alone.
  public var minTopCosine: Float? = nil
  /// Refuse when the best z minus the `gapRank`-th best z is under this: real matches stand out of the crowd at the
  /// top, chance hits form a smooth tail.
  public var minTopGap: Float? = nil
  /// 50: the eval found nothing relevant past rank 50 for a typical query, so that is where the crowd starts.
  public var gapRank = 50
  /// Refuse only when every configured test fails (false: when any one fails).
  public var requireAll = false

  public init(minTopZ: Float? = nil, minTopCosine: Float? = nil, minTopGap: Float? = nil, gapRank: Int = 50,
              requireAll: Bool = false) {
    self.minTopZ = minTopZ; self.minTopCosine = minTopCosine; self.minTopGap = minTopGap
    self.gapRank = gapRank; self.requireAll = requireAll
  }

  public var isOff: Bool { minTopZ == nil && minTopCosine == nil && minTopGap == nil }

  /// Whether to refuse, from the best meaning z values (descending; at least `gapRank` of them when the library has
  /// that many) and the best cosine. A gap test without a `gapRank`-th value passes: too few photos to call a crowd.
  public func refuses(topZ: [Float], topCosine: Float?) -> Bool {
    var failed: [Bool] = []
    if let minTopZ { failed.append((topZ.first ?? -.infinity) < minTopZ) }
    if let minTopCosine { failed.append((topCosine ?? -.infinity) < minTopCosine) }
    if let minTopGap {
      let k = max(gapRank, 1)
      failed.append(topZ.count >= k && topZ[0] - topZ[k - 1] < minTopGap)
    }
    guard !failed.isEmpty else { return false }
    return requireAll ? failed.allSatisfy { $0 } : failed.contains(true)
  }
}
