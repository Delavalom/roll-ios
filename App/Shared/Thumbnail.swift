import CoreGraphics
import Foundation
import Library
import SwiftUI

/// Where thumbnails come from: PhotoKit in the app, generated images in previews. Swipe cards and full screen go
/// through `CardImageSource` (`CardImageLoader` picks each request).
protocol ThumbnailProvider: CardImageSource {
  func image(for id: String, side: Int) async -> CGImage?
}

extension ThumbnailProvider {
  /// Previews: the generated image, never a download.
  func image(for id: String, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult {
    if spec.allowsNetwork { return .failed }
    return await image(for: id, side: side).map(ThumbnailResult.image) ?? .failed
  }
}

/// No images (the environment default until the app installs its provider).
struct NoThumbnails: ThumbnailProvider {
  func image(for id: String, side: Int) async -> CGImage? { nil }
}

/// Local PhotoKit thumbnails, cached in memory up to `costLimit` bytes of decoded pixels. Full-screen sizes
/// (`side >= uncachedSide`) aren't cached: one is several megabytes and is seen once. Network access stays off here,
/// except for card requests with `ImageRequestSpec.download`, which `CardImageLoader` makes only on Wi-Fi.
final class PhotoThumbnails: ThumbnailProvider, @unchecked Sendable {
  static let costLimit = 120 * 1024 * 1024
  static let uncachedSide = 2000

  // NSCache is thread-safe; the class holds nothing else.
  private let cache = NSCache<NSString, CGImageBox>()
  private let library = PhotoLibrary()

  init() {
    cache.totalCostLimit = Self.costLimit
    cache.countLimit = 1_000
  }

  func image(for id: String, side: Int) async -> CGImage? {
    let key = "\(side)|\(id)" as NSString
    if let hit = cache.object(forKey: key) { return hit.image }
    guard let image = await library.thumbnail(id: id, side: side).image else { return nil }
    if side < Self.uncachedSide {
      cache.setObject(CGImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
    }
    return image
  }

  /// Card requests. A full local or downloaded image is cached as the sharp image for its size (so a later offline
  /// request for that size finds it); a preview under its own key. "In iCloud" and failures aren't cached.
  func image(for id: String, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult {
    let sharpKey = "card|\(side)|\(id)" as NSString, previewKey = "card-preview|\(side)|\(id)" as NSString
    if let hit = cache.object(forKey: sharpKey) { return .image(hit.image) }
    if spec == .localBest, let hit = cache.object(forKey: previewKey) { return .preview(hit.image) }
    let result = await library.image(id: id, side: side, spec: spec)
    if side < Self.uncachedSide {
      switch result {
      case .image(let image): cache.setObject(CGImageBox(image), forKey: sharpKey, cost: image.bytesPerRow * image.height)
      case .preview(let image): cache.setObject(CGImageBox(image), forKey: previewKey, cost: image.bytesPerRow * image.height)
      default: break
      }
    }
    return result
  }

  private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }
}

extension EnvironmentValues {
  @Entry var thumbnails: any ThumbnailProvider = NoThumbnails()
}

/// A square-filled thumbnail of one asset, with a neutral placeholder while it loads (or when it's only in iCloud).
/// Swipe cards and full screen use `CardPhoto` instead, which never leaves a blank.
struct Thumbnail: View {
  let id: String
  var side = 300

  @Environment(\.thumbnails) private var provider
  @State private var image: CGImage?

  var body: some View {
    Rectangle()
      .fill(.rollWell)
      .overlay {
        if let image {
          Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
        }
      }
      .clipped()
      .task(id: id) { image = await provider.image(for: id, side: side) }
      .accessibilityHidden(true)
  }
}
