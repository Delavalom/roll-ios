import Foundation
import Store

/// A video's resolution change, so the UI can say "1080p (from 4K)".
public struct Downscale: Sendable, Equatable {
  public let fromW: Int, fromH: Int, toW: Int, toH: Int

  public init(fromW: Int, fromH: Int, toW: Int, toH: Int) {
    self.fromW = fromW; self.fromH = fromH; self.toW = toW; self.toH = toH
  }

  /// The 1080p box (1920x1080, either orientation). `nil` when `keep4K` or the source already fits.
  public static func forSource(w: Int, h: Int, keep4K: Bool) -> Downscale? {
    guard !keep4K, w > 0, h > 0 else { return nil }
    let long = Double(max(w, h)), short = Double(min(w, h))
    let scale = min(1920 / long, 1080 / short)
    guard scale < 1 else { return nil }
    func even(_ v: Double) -> Int { max(2, Int((v * scale).rounded()) & ~1) }
    return Downscale(fromW: w, fromH: h, toW: even(Double(w)), toH: even(Double(h)))
  }
}

public struct SquishPlanItem: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable { case photo, video }

  public let assetID: String
  public let kind: Kind
  public let estimatedBytes: Int64
  public let estimatedOutputBytes: Int64
  /// Set when a video will come out smaller than its source resolution (the UI shows this).
  public let downscale: Downscale?
  public var id: String { assetID }
  public var estimatedSavings: Int64 { estimatedBytes - estimatedOutputBytes }
  public var savingsFraction: Double { estimatedBytes > 0 ? Double(estimatedSavings) / Double(estimatedBytes) : 0 }
}

/// Chooses which candidates are worth squishing and estimates the result. Estimates are heuristics: the
/// real saving is measured after encoding, and the UI always says "about".
public enum SquishPlanner {
  /// Shared with the UI: an item must be expected to save at least this fraction of its size.
  public static let minimumSavingsFraction = 0.30
  /// Typical output size relative to the source for a HEIC re-encode at quality 0.8.
  public static let jpegToHEICRatio = 0.6
  public static let pngToHEICRatio = 0.25

  /// What the confirm sheet must tell the user cannot be carried over (see `SquishLimitations`).
  public static var transferLimitations: [String] { SquishLimitations.items }

  /// - Parameters:
  ///   - excluding: ids Roll must not offer, typically `Repositories.journaledCopyIDs()` (copies Roll made itself).
  ///   - videoFacts: what the format probe measured (`Repositories.videoProbeFacts()`); videos without facts are
  ///     planned from the Store's estimate.
  public static func plan(records: [AssetRecord], keep4K: Bool, excluding: Set<String> = [],
                          videoFacts: [String: VideoProbeFacts] = [:]) -> [SquishPlanItem] {
    records.filter { !excluding.contains($0.id) }.compactMap { offer(for: $0, keep4K: keep4K, facts: videoFacts[$0.id]) }
  }

  /// The per-item estimate behind `plan`: what squishing `record` would produce, or nil when Squish wouldn't offer
  /// it (not a candidate, or expected to save less than `minimumSavingsFraction`). Home sums these for big videos.
  /// `facts` (a video's probe) replace the estimated size and frame rate with measured ones, and an HEVC source kept
  /// at its own size is planned at `SquishCandidates.hevcReencodeBitsPerPixel`.
  public static func offer(for record: AssetRecord, keep4K: Bool, facts: VideoProbeFacts? = nil) -> SquishPlanItem? {
    item(for: record, keep4K: keep4K, facts: facts).flatMap { $0.savingsFraction >= minimumSavingsFraction ? $0 : nil }
  }

  static func item(for r: AssetRecord, keep4K: Bool, facts: VideoProbeFacts? = nil) -> SquishPlanItem? {
    guard SquishCandidates.isCandidate(r, facts: facts) else { return nil }
    if r.mediaType == SquishCandidates.imageMediaType {
      let ratio = r.uti == "public.png" ? pngToHEICRatio : jpegToHEICRatio
      return SquishPlanItem(assetID: r.id, kind: .photo, estimatedBytes: r.estBytes,
                            estimatedOutputBytes: Int64(Double(r.estBytes) * ratio), downscale: nil)
    }
    let bytes = SquishCandidates.sourceBytes(r, facts: facts)
    guard let seconds = r.duration, seconds > 0, bytes > 0 else { return nil }
    let down = Downscale.forSource(w: r.pixelW ?? 0, h: r.pixelH ?? 0, keep4K: keep4K)
    let sourceBitrate = Double(bytes) * 8 / seconds
    let bitsPerPixel = facts?.isHEVC == true && down == nil
      ? SquishCandidates.hevcReencodeBitsPerPixel : SquishCandidates.hevcBitsPerPixel
    let bitrate = SquishCandidates.plannedOutputBitrate(pixelW: down?.toW ?? r.pixelW, pixelH: down?.toH ?? r.pixelH,
                                                        fps: SquishCandidates.frameRate(facts),
                                                        bitsPerPixel: bitsPerPixel, sourceBitrate: sourceBitrate)
    let out = min(bytes, Int64(bitrate * seconds / 8))
    return SquishPlanItem(assetID: r.id, kind: .video, estimatedBytes: bytes, estimatedOutputBytes: out, downscale: down)
  }
}
