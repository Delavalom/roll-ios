// UIKit only: this file compiles into the test bundle on iOS and is empty on macOS, so it runs
// when the package tests run on an iOS simulator or device, never in `swift test` on the Mac.
#if canImport(UIKit) && os(iOS)
import UIKit
import Testing
@testable import Library

struct UprightImageTests {
  /// 20×10 image: left half red, right half blue.
  static func twoToneCGImage() -> CGImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10),
                                           format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
    return renderer.image { context in
      UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
      UIColor.blue.setFill(); context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
    }.cgImage!
  }

  static func rgb(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { buffer in
      let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }
    return (pixel[0], pixel[1], pixel[2])
  }

  @Test func upImageIsReturnedUntouched() throws {
    let cg = Self.twoToneCGImage()
    let out = try #require(UprightImage.cgImage(from: UIImage(cgImage: cg, scale: 1, orientation: .up)))
    #expect(out === cg)
  }

  @Test func rotatedImageIsRedrawnUpright() throws {
    // .right = displayed rotated 90 degrees clockwise: the left (red) edge ends up on top.
    let cg = Self.twoToneCGImage()
    let out = try #require(UprightImage.cgImage(from: UIImage(cgImage: cg, scale: 1, orientation: .right)))
    #expect(out.width == 10 && out.height == 20)
    let top = Self.rgb(of: out, x: 5, y: 3), bottom = Self.rgb(of: out, x: 5, y: 16)
    #expect(top.r > 200 && top.b < 60)
    #expect(bottom.b > 200 && bottom.r < 60)
  }
}
#endif
