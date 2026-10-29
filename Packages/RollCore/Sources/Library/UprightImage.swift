#if canImport(UIKit) && os(iOS)
import UIKit

/// PhotoKit hands back `UIImage`s whose `cgImage` can still be in sensor orientation, with the
/// rotation carried only by `imageOrientation`. The redraw is CPU work: call it off the main thread. Vision, the blur score and the embedder read raw
/// pixels, so everything downstream gets pixels that are already upright.
enum UprightImage {
  /// The image's own `cgImage` when it is already `.up`; otherwise a redraw at the displayed pixel size.
  static func cgImage(from image: UIImage) -> CGImage? {
    guard let cgImage = image.cgImage else { return nil }
    if image.imageOrientation == .up { return cgImage }
    // `size` is in points and already reflects the orientation; scale back to pixels.
    let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    format.preferredRange = .standard  // upright sRGB pixels, no extended-range surprises downstream
    let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: pixelSize)) }.cgImage
  }
}
#endif
