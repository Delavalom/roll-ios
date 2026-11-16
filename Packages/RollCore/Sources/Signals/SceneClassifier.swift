import CoreGraphics
import Foundation
import Vision

/// One Vision scene label: the classifier's identifier ("beach", "wedding_dress") and its confidence 0…1.
public struct SceneLabel: Sendable, Equatable {
  public var identifier: String
  public var confidence: Float

  public init(identifier: String, confidence: Float) {
    self.identifier = identifier
    self.confidence = confidence
  }
}

/// Scene labels for typed search's tags (Find V4, the tag pass `TagIndexer`): `VNClassifyImageRequest`, kept from
/// `minConfidence`, best first, at most `maxLabels`. The defaults are the find eval's (`App/QA/QAFindExporter`:
/// confidence >= 0.1, top 10, on a ~360 px local image), where tags lifted P@20 from .823 to .841.
public struct SceneClassifier: Sendable {
  public let minConfidence: Float
  public let maxLabels: Int

  public init(minConfidence: Float = 0.1, maxLabels: Int = 10) {
    self.minConfidence = minConfidence
    self.maxLabels = maxLabels
  }

  /// Names the settings; stored with each photo's tags so a change reads every photo again.
  public var revision: String { "vision-classify-\(minConfidence)x\(maxLabels)-1" }

  /// The kept labels; [] when none clears `minConfidence`. Nil if Vision failed. Throws only on cancellation.
  public func classify(_ image: CGImage) async throws(CancellationError) -> [SceneLabel]? {
    if Task.isCancelled { throw CancellationError() }
    let labels: [SceneLabel]? = autoreleasepool {
      let request = VNClassifyImageRequest()
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      do { try handler.perform([request]) } catch {
        SignalLog.logger.debug("scene classification failed: \(String(describing: error))")
        return nil
      }
      return (request.results ?? [])
        .filter { $0.confidence >= minConfidence }
        .sorted { $0.confidence > $1.confidence }
        .prefix(maxLabels)
        .map { SceneLabel(identifier: $0.identifier, confidence: $0.confidence) }
    }
    if Task.isCancelled { throw CancellationError() }
    return labels
  }
}
