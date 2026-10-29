import CoreGraphics
import Foundation
import ImageIO

/// Fixture images built by `scripts/make_test_fixtures.py` (see there for provenance).
enum Fixtures {
  enum Failure: Error { case missing(String) }

  static func image(_ name: String) throws -> CGImage {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw Failure.missing(name) }
    return image
  }

  static func solid(width: Int, height: Int, gray: UInt8) -> CGImage {
    var bytes = [UInt8](repeating: gray, count: width * height)
    // makeImage() copies the pixels, so it must run while the buffer pointer is still valid.
    return bytes.withUnsafeMutableBytes {
      CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
    }
  }
}
