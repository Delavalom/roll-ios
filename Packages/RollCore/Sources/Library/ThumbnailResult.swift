import CoreGraphics
import Foundation

/// Outcome of a thumbnail or video-frame request. `inCloud` is not an error: the original is only in
/// iCloud and the request did not allow network access (the Indexer marks the asset `cloudOnly` and
/// retries later on Wi-Fi). `preview` is the small local preview the library keeps for such an original
/// (the degraded image of an opportunistic request): good enough for Vision signals and swipe cards, and
/// recorded as `source = preview`. `cancelled` means the calling task was cancelled (or PhotoKit reported
/// `PHImageCancelledKey`): not a property of the asset, so callers must not mark it failed or cloud-only.
/// `failed` covers errors.
public enum ThumbnailResult: Sendable {
  case image(CGImage)
  case preview(CGImage)
  case inCloud
  case failed
  case cancelled

  /// The full image or the local preview.
  public var image: CGImage? {
    switch self {
    case .image(let image), .preview(let image): image
    default: nil
    }
  }

  public var isPreview: Bool {
    if case .preview = self { return true }
    return false
  }

  /// Maps what a PhotoKit result handler reports (`PHImageResultIsInCloudKey`, `PHImageErrorKey`).
  /// With network access off, an iCloud-only asset delivers no final image, `isInCloud == true`, and usually
  /// an error too, so the cloud flag wins. With network access on, a cloud flag plus an error is a
  /// failed download. `preview` is the last degraded image delivered before the final call: it is the result
  /// only when the final call says why the full image is missing (in iCloud, or an error); a silent miss is a
  /// failure, not evidence about where the original is.
  static func classify(image: CGImage?, isInCloud: Bool, hasError: Bool, cancelled: Bool = false,
                       allowNetwork: Bool, preview: CGImage? = nil) -> ThumbnailResult {
    if let image { return .image(image) }
    if cancelled { return .cancelled }
    if let preview, isInCloud || hasError { return .preview(preview) }
    if isInCloud && (!allowNetwork || !hasError) { return .inCloud }
    return .failed
  }
}
