import CoreGraphics
import CoreVideo
import Memories

/// Draws reel frames: aspect fill (never letterboxed) with a slow Ken Burns zoom and pan, and the crossfade between
/// two shots. Pure CoreGraphics on the pixel buffer's own memory; no state.
enum ReelFrameRenderer {
  static let width = 1080
  static let height = 1920
  static let crossfade = 0.3
  /// 1.00 to 1.08 over a shot (reversed on every other shot).
  static let zoomRange = 0.08
  /// Horizontal drift over a shot, as a share of the frame width (alternating direction).
  static let panShare = 0.03

  struct Layer {
    var frame: ReelFrame
    /// 0...1 through the shot, for the Ken Burns move.
    var progress: Double
    /// Index of the shot in the cut: even shots zoom in and drift right, odd ones zoom out and drift left.
    var index: Int
    var alpha: Double
  }

  /// Where the image lands in the frame (CG coordinates, origin bottom-left). Always covers the whole frame.
  static func rect(for layer: Layer) -> CGRect {
    let w = Double(width), h = Double(height)
    let iw = Double(layer.frame.image.width), ih = Double(layer.frame.image.height)
    let p = min(max(layer.progress, 0), 1)
    let forward = layer.index % 2 == 0
    let zoom = 1 + zoomRange * (forward ? p : 1 - p)
    let scale = max(w / iw, h / ih) * zoom
    let dw = iw * scale, dh = ih * scale
    let drift = (p - 0.5) * panShare * w * (forward ? 1 : -1)
    let x = min(0, max(w - dw, w / 2 - layer.frame.focus.x * dw + drift))
    let y = min(0, max(h - dh, h / 2 - layer.frame.focus.y * dh))
    return CGRect(x: x, y: y, width: dw, height: dh)
  }

  static func render(_ layers: [Layer], into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .medium
    for layer in layers {
      context.setAlpha(layer.alpha)
      context.draw(layer.frame.image, in: rect(for: layer))
    }
  }

  /// How the shot at `time` is shown: the shot, and during its last `crossfade` seconds the next one fading in.
  /// The fade eases (smoothstep) so it has no visible start or stop.
  static func blend(at time: Double, shots: [ReelShot]) -> (index: Int, nextAlpha: Double)? {
    guard let index = shots.lastIndex(where: { $0.start <= time + 1e-9 }), time < shots[index].end + 1e-9 else { return nil }
    guard index + 1 < shots.count else { return (index, 0) }
    let into = (time - (shots[index].end - crossfade)) / crossfade
    guard into > 0 else { return (index, 0) }
    let x = min(1, into)
    return (index, x * x * (3 - 2 * x))
  }
}
