import CoreGraphics

/// 8-bit grayscale pixels drawn from a `CGImage`.
struct GrayBitmap {
  let width: Int
  let height: Int
  /// Row-major, `width * height` bytes.
  let pixels: [UInt8]

  /// Draws `image` into a `width`×`height` DeviceGray context with high-quality interpolation,
  /// ignoring aspect ratio (callers pick the target size).
  static func render(_ image: CGImage, width: Int, height: Int) -> GrayBitmap? {
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .high
      // Flatten any transparency onto white so alpha does not read as black.
      context.setFillColor(gray: 1, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? GrayBitmap(width: width, height: height, pixels: pixels) : nil
  }

  /// The shared analysis bitmap: grayscale, longer side at most `BlurScore.analysisSide`. Render it once
  /// per image and feed both the blur score and the perceptual hash.
  static func analysis(_ image: CGImage) -> GrayBitmap? {
    let size = fittedSize(of: image, maxSide: BlurScore.analysisSide)
    return render(image, width: size.width, height: size.height)
  }

  /// Aspect-preserving size whose longer side is at most `maxSide` (images are never upscaled).
  static func fittedSize(of image: CGImage, maxSide: Int) -> (width: Int, height: Int) {
    let w = Double(image.width), h = Double(image.height)
    let scale = min(1, Double(maxSide) / max(w, h))
    return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
  }
}
