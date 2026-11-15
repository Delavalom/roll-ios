import CoreGraphics
import Vision

/// Cheap face-safe centering: the middle of the faces Vision finds, else the image centre.
enum FaceFocus {
  static func focus(in image: CGImage) -> CGPoint {
    let request = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil, let faces = request.results, !faces.isEmpty else {
      return CGPoint(x: 0.5, y: 0.5)
    }
    let union = faces.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
    return CGPoint(x: union.midX, y: union.midY)
  }
}
