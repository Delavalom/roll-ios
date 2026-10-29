import CoreGraphics
import Vision

/// Vision aesthetics: `overall` (about -1...1, low = poor) and `isUtility` (screenshots, receipts,
/// documents and other non-photographic captures).
public enum Aesthetics {
  public struct Result: Sendable, Equatable {
    public var overall: Float
    public var isUtility: Bool
    public init(overall: Float, isUtility: Bool) { self.overall = overall; self.isUtility = isUtility }
  }

  /// True when the SDK exposes the request. A host without the Neural Engine path can still throw
  /// at runtime; `SignalExtractor` turns that into nil fields.
  public static var isSupported: Bool {
    !CalculateImageAestheticsScoresRequest.supportedRevisions.isEmpty
  }

  public static func compute(_ image: CGImage) async throws -> Result {
    let observation = try await CalculateImageAestheticsScoresRequest().perform(on: image)
    return Result(overall: observation.overallScore, isUtility: observation.isUtility)
  }

  static func result(_ observation: ImageAestheticsScoresObservation) -> Result {
    Result(overall: observation.overallScore, isUtility: observation.isUtility)
  }
}
