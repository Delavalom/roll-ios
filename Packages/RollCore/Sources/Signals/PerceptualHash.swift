import Accelerate
import CoreGraphics

/// 64-bit difference hash: a 9×8 grayscale thumbnail, one bit per horizontal neighbour pair
/// (set when the left pixel is brighter than the right one).
///
/// The thumbnail is scaled down (vImage, Lanczos) from the same 256-px grayscale bitmap the blur
/// score uses, so the image is rendered once.
///
/// **Degenerate hashes:** a flat image (black frame, white wall, a solid-colour screenshot) has no
/// brighter-than-neighbour pixels and hashes to 0, and a saturated pattern can hash to all ones.
/// Unrelated photos collide on those values, so consumers must not treat an equal degenerate hash
/// as a duplicate; `DuplicateGrouper` excludes them.
public enum PerceptualHash {
  public static func dHash(_ image: CGImage) -> UInt64? {
    guard let gray = GrayBitmap.analysis(image) else { return nil }
    return dHash(gray)
  }

  static func dHash(_ gray: GrayBitmap) -> UInt64? {
    let width = 9, height = 8
    var small = [UInt8](repeating: 0, count: width * height)
    var source = gray.pixels
    let scaled: vImage_Error = source.withUnsafeMutableBytes { sourcePtr in
      small.withUnsafeMutableBytes { smallPtr in
        var src = vImage_Buffer(
          data: sourcePtr.baseAddress!, height: vImagePixelCount(gray.height), width: vImagePixelCount(gray.width),
          rowBytes: gray.width)
        var dst = vImage_Buffer(
          data: smallPtr.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width),
          rowBytes: width)
        return vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
      }
    }
    guard scaled == kvImageNoError else {
      SignalLog.logger.debug("dHash: vImageScale_Planar8 failed with \(scaled)")
      return nil
    }
    var hash: UInt64 = 0
    for row in 0..<height {
      for col in 0..<(width - 1) {
        hash <<= 1
        if small[row * width + col] > small[row * width + col + 1] { hash |= 1 }
      }
    }
    return hash
  }

  public static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
