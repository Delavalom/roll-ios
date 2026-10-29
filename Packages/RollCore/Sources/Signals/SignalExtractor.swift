import CoreGraphics
import Foundation

/// Everything Vision-side Roll learns about one image. A nil field means "not available", never "false".
public struct AssetSignals: Sendable, Equatable {
  /// Laplacian variance (see `BlurScore`).
  public var blur: Float?
  /// `CalculateImageAestheticsScoresRequest.overallScore`.
  public var aesthetic: Float?
  public var isUtility: Bool?
  /// Nil unless Sensitive Content Analysis is enabled (see `Sensitive`).
  public var sensitive: Bool?
  public var phash: UInt64?
  /// Raw-float feature print (see `FeaturePrints` for the format).
  public var featurePrint: Data?

  public init(blur: Float? = nil, aesthetic: Float? = nil, isUtility: Bool? = nil, sensitive: Bool? = nil,
              phash: UInt64? = nil, featurePrint: Data? = nil) {
    self.blur = blur; self.aesthetic = aesthetic; self.isUtility = isUtility; self.sensitive = sensitive
    self.phash = phash; self.featurePrint = featurePrint
  }
}

/// Computes `AssetSignals`. Run images one after another (see `VisionBatch`); call `refreshPolicy()`
/// once per indexing batch so the sensitivity policy is read per batch, not per image.
public struct SignalExtractor: Sendable {
  private let analyzer: any SensitivityAnalyzing

  public init(analyzer: any SensitivityAnalyzing = SystemSensitivityAnalyzer()) { self.analyzer = analyzer }

  /// Re-reads the Sensitive Content Analysis policy (cached between calls).
  public func refreshPolicy() { analyzer.refreshPolicy() }

  /// A failing signal leaves its fields nil. The only error is cancellation: if the task was cancelled
  /// the partial result is discarded so the Indexer never commits half-computed signals.
  public func extract(_ image: CGImage) async throws(CancellationError) -> AssetSignals {
    if Task.isCancelled { throw CancellationError() }
    var signals = AssetSignals()
    if let gray = GrayBitmap.analysis(image) {
      signals.blur = BlurScore.score(gray)
      signals.phash = PerceptualHash.dHash(gray)
    } else {
      SignalLog.logger.debug("analysis bitmap could not be rendered")
    }
    if signals.blur == nil { SignalLog.logger.debug("blur score unavailable") }
    if signals.phash == nil { SignalLog.logger.debug("perceptual hash unavailable") }

    // The sensitivity analyzer and the Vision requests are independent; run them side by side.
    async let sensitive = Sensitive.check(image, analyzer: analyzer)
    let vision = await VisionBatch.run(image)
    signals.featurePrint = vision.featurePrint
    signals.aesthetic = vision.aesthetics?.overall
    signals.isUtility = vision.aesthetics?.isUtility
    signals.sensitive = await sensitive
    if Task.isCancelled { throw CancellationError() }
    return signals
  }
}
