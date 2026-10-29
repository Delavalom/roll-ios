import Accelerate
import CoreGraphics

/// Sharpness as the variance of the 3×3 Laplacian of a 256-px grayscale thumbnail (0...255 scale).
/// Higher is sharper; flat or defocused images score near zero. The "blurry" cutoff is not defined
/// here: it is `Store.AssetRecord.blurryBelow`, the one canonical value.
public enum BlurScore {
  /// Longer side of the analysis thumbnail.
  public static let analysisSide = 256

  /// Nil when the image cannot be rendered or is smaller than 3 px on a side.
  public static func score(_ image: CGImage) -> Float? {
    guard let gray = GrayBitmap.analysis(image) else { return nil }
    return score(gray)
  }

  static func score(_ gray: GrayBitmap) -> Float? {
    guard gray.width >= 3, gray.height >= 3 else { return nil }
    return laplacianVariance(gray)
  }

  static func laplacianVariance(_ gray: GrayBitmap) -> Float? {
    let count = gray.width * gray.height
    let rowBytesF = gray.width * MemoryLayout<Float>.stride
    var source = [Float](repeating: 0, count: count)
    var response = [Float](repeating: 0, count: count)
    let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
    var error: vImage_Error = vImage_Error(kvImageNoError)
    let height = vImagePixelCount(gray.height), width = vImagePixelCount(gray.width)

    gray.pixels.withUnsafeBufferPointer { pixelPtr in
      source.withUnsafeMutableBufferPointer { sourcePtr in
        response.withUnsafeMutableBufferPointer { responsePtr in
          var src8 = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: pixelPtr.baseAddress!), height: height, width: width,
            rowBytes: gray.width)
          var srcF = vImage_Buffer(data: sourcePtr.baseAddress!, height: height, width: width, rowBytes: rowBytesF)
          var dstF = vImage_Buffer(data: responsePtr.baseAddress!, height: height, width: width, rowBytes: rowBytesF)
          error = vImageConvert_Planar8toPlanarF(&src8, &srcF, 255, 0, vImage_Flags(kvImageNoFlags))
          guard error == kvImageNoError else { return }
          error = kernel.withUnsafeBufferPointer { kernelPtr in
            vImageConvolve_PlanarF(
              &srcF, &dstF, nil, 0, 0, kernelPtr.baseAddress!, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
          }
        }
      }
    }
    guard error == kvImageNoError else { return nil }

    var mean: Float = 0, meanSquare: Float = 0
    vDSP_meanv(response, 1, &mean, vDSP_Length(count))
    vDSP_measqv(response, 1, &meanSquare, vDSP_Length(count))
    return max(0, meanSquare - mean * mean)
  }
}
