import CoreGraphics
import Foundation
import Vision

/// The two Vision requests Roll needs per image, run through one `ImageRequestHandler` so the image
/// is prepared once. If the combined call throws (or aesthetics is unsupported), each request is
/// retried on its own, so a failing signal leaves only its own result nil.
///
/// Callers (the Indexer) run images sequentially: Vision already parallelises inside a request, and
/// concurrent handlers only add memory pressure.
enum VisionBatch {
  struct Output: Sendable {
    var featurePrint: Data?
    var aesthetics: Aesthetics.Result?
  }

  static func run(_ image: CGImage) async -> Output {
    if Aesthetics.isSupported {
      do {
        let (print, aesthetics) = try await ImageRequestHandler(image).perform(
          FeaturePrints.makeRequest(), CalculateImageAestheticsScoresRequest())
        let data = encodeLogging(print)
        return Output(featurePrint: data, aesthetics: Aesthetics.result(aesthetics))
      } catch is CancellationError {
        return Output()  // cancelled: the extractor discards the result, so skip the retries
      } catch {
        if Task.isCancelled { return Output() }
        SignalLog.logger.debug("combined Vision request failed, retrying separately: \(String(describing: error))")
      }
    }
    var output = Output()
    do { output.featurePrint = try await FeaturePrints.compute(image) }
    catch is CancellationError { return Output() }
    catch { SignalLog.logger.debug("feature print failed: \(String(describing: error))") }
    if Task.isCancelled { return output }
    if Aesthetics.isSupported {
      do { output.aesthetics = try await Aesthetics.compute(image) }
      catch is CancellationError { return output }
      catch { SignalLog.logger.debug("aesthetics failed: \(String(describing: error))") }
    }
    return output
  }

  private static func encodeLogging(_ observation: FeaturePrintObservation) -> Data? {
    do { return try FeaturePrints.encode(observation) }
    catch { SignalLog.logger.debug("feature print encode failed: \(String(describing: error))"); return nil }
  }
}
