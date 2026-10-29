import CoreGraphics
import Foundation
import Vision

/// Reads the words in an image with Vision (`RecognizeTextRequest`), for keyword search over screenshots, receipts and
/// documents (the text pass, `TextIndexer`, decides which images and at what size).
///
/// Defaults chosen on the Mac (evidence: docs/investigations/evidence/2026-10-29-ocr/mac-ocr.json, M1 Pro, 28 seed
/// images with text): `.accurate` at a 960 px long side found 93% of the reference words in a median 264 ms; `.fast`
/// found 20% (almost nothing on screenshots and receipts) at any size. Language correction found 1.3 points more for a
/// third more time (351 ms) and rewrites the names, handles and numbers people search for, so it's off.
/// Size matters more than either: at Roll's 300 px analysis thumbnail `.accurate` found 30% (4-16% on screenshots).
public struct TextRecognizer: Sendable {
  public enum Level: String, Sendable { case fast, accurate }

  public let level: Level
  public let languageCorrection: Bool

  public init(level: Level = .accurate, languageCorrection: Bool = false) {
    self.level = level
    self.languageCorrection = languageCorrection
  }

  /// Names the settings; stored with each text so a change of settings reads every image again. The trailing number
  /// is bumped when the text a setting produces changes for another reason (an OS model update doesn't count).
  public var revision: String { "vision-text-\(level.rawValue)\(languageCorrection ? "-lc" : "")-1" }

  /// The recognised lines, top candidate each, joined by newlines; "" when the image has no text. Nil if Vision
  /// failed. Throws only on cancellation (the partial result is discarded).
  public func recognize(_ image: CGImage) async throws(CancellationError) -> String? {
    if Task.isCancelled { throw CancellationError() }
    var request = RecognizeTextRequest()
    request.recognitionLevel = level == .accurate ? .accurate : .fast
    request.usesLanguageCorrection = languageCorrection
    let observations: [RecognizedTextObservation]
    do {
      observations = try await request.perform(on: image)
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      SignalLog.logger.debug("text recognition failed: \(String(describing: error))")
      return nil
    }
    if Task.isCancelled { throw CancellationError() }
    return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
  }
}
