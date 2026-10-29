import CoreGraphics
import Foundation
import SensitiveContentAnalysis

/// Seam over `SCSensitivityAnalyzer` so the nil path (policy disabled) and the answer path are testable.
public protocol SensitivityAnalyzing: Sendable {
  /// False when the user or the entitlement leaves analysis switched off. Cached: it reflects the
  /// policy as of the last `refreshPolicy()`.
  var isEnabled: Bool { get }
  /// Re-reads the system policy. The Indexer calls this once per batch, not once per image.
  func refreshPolicy()
  func isSensitive(_ image: CGImage) async throws -> Bool
}

public final class SystemSensitivityAnalyzer: SensitivityAnalyzing, @unchecked Sendable {
  private let analyzer = SCSensitivityAnalyzer()
  private let lock = NSLock()
  private var enabled: Bool

  public init() { enabled = analyzer.analysisPolicy != .disabled }

  public var isEnabled: Bool { lock.withLock { enabled } }

  public func refreshPolicy() {
    let policy = analyzer.analysisPolicy != .disabled
    lock.withLock { enabled = policy }
  }

  public func isSensitive(_ image: CGImage) async throws -> Bool {
    try await analyzer.analyzeImage(image).isSensitive
  }
}

/// Sensitive-content flag. Nil means "unknown": the policy is `.disabled` (no entitlement, or the
/// user has not turned Sensitive Content Warning / Communication Safety on) or analysis failed.
public enum Sensitive {
  public static func check(_ image: CGImage, analyzer: some SensitivityAnalyzing) async -> Bool? {
    guard analyzer.isEnabled else { return nil }
    do { return try await analyzer.isSensitive(image) }
    catch {
      SignalLog.logger.debug("sensitivity analysis failed: \(String(describing: error))")
      return nil
    }
  }
}
