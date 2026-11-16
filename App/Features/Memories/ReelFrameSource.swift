import CoreGraphics
import Foundation
import Memories

/// One decoded picture for the reel, upright, plus where its subject is.
struct ReelFrame: Sendable {
  var image: CGImage
  /// Where the crop should centre, in the image's own unit square with the origin bottom-left (0.5, 0.5 = centre).
  /// Faces pull it toward them so an aspect-fill crop of a wide photo keeps people in frame.
  var focus: CGPoint

  static func centred(_ image: CGImage) -> ReelFrame { ReelFrame(image: image, focus: CGPoint(x: 0.5, y: 0.5)) }
}

/// Where the exporter gets pictures: PhotoKit in the app (`PhotoKitReelSource`), generated images in tests.
protocol ReelFrameSource: Sendable {
  /// The picture for `shot` at `localTime` seconds into the shot; nil when the asset can't be read.
  func frame(for shot: ReelShot, at localTime: Double) async -> ReelFrame?
  /// A hint that `shot` is about to be needed (load it while the current shot plays).
  func prepare(_ shot: ReelShot) async
}
