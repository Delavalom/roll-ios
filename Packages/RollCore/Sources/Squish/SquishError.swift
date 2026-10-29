import Foundation

public struct SquishResult: Sendable, Equatable {
  public let inputBytes: Int64
  public let outputBytes: Int64
  public var bytesSaved: Int64 { inputBytes - outputBytes }

  public init(inputBytes: Int64, outputBytes: Int64) {
    self.inputBytes = inputBytes
    self.outputBytes = outputBytes
  }
}

public enum SquishError: Error, Sendable {
  /// The re-encoded file isn't at least 20% smaller (`SquishVerify.maxSizeRatio`). The output is deleted.
  case notSmaller
  /// The re-encoded video's duration differs from the original by more than 0.1 s. The output is deleted.
  case durationMismatch
  /// Reading, encoding or writing failed. Carries the underlying error.
  case exportFailed(any Error)
  /// This device can't produce the requested format (e.g. no HEIC or HEVC encoder).
  case unsupported
  /// The asset must not be squished (checked before or during encoding).
  case ineligible(IneligibilityReason)
  /// The re-encoded file failed a post-encode check (decode, colour profile, audio track). The output is deleted.
  case verificationFailed(String)
  /// The surrounding task was cancelled. The partial output is deleted.
  case cancelled
}

extension SquishError: Equatable {
  /// `exportFailed` values compare equal when their underlying errors bridge to the same `NSError`.
  public static func == (lhs: SquishError, rhs: SquishError) -> Bool {
    switch (lhs, rhs) {
    case (.notSmaller, .notSmaller), (.durationMismatch, .durationMismatch),
         (.unsupported, .unsupported), (.cancelled, .cancelled): true
    case let (.ineligible(a), .ineligible(b)): a == b
    case let (.verificationFailed(a), .verificationFailed(b)): a == b
    case let (.exportFailed(a), .exportFailed(b)): (a as NSError) == (b as NSError)
    default: false
    }
  }
}

/// Shared acceptance rules for a re-encoded file (spec §8).
enum SquishVerify {
  /// Output must be at most this fraction of the input (that is, at least 20% smaller).
  static let maxSizeRatio = 0.8
  /// Allowed difference between input and output video duration, in seconds.
  static let durationTolerance = 0.1

  static func fileSize(_ url: URL) throws -> Int64 {
    Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
  }

  static func isSmallEnough(input: Int64, output: Int64) -> Bool {
    output > 0 && Double(output) <= maxSizeRatio * Double(input)
  }
}
