import CoreGraphics
import Testing
@testable import Library

/// iCloud-only originals: the library still has a small local preview (the degraded image an opportunistic request
/// delivers first). The Indexer analyses it and swipe cards show it, instead of a blank.
struct ThumbnailPreviewTests {
  static func image(_ side: Int) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    return context.makeImage()!
  }

  @Test func theFinalImageWinsOverAPreview() {
    let final = Self.image(4), preview = Self.image(2)
    let result = ThumbnailResult.classify(image: final, isInCloud: false, hasError: false, allowNetwork: false,
                                          preview: preview)
    guard case .image(let got) = result else { Issue.record("expected the full image"); return }
    #expect(got.width == 4)
    #expect(!result.isPreview)
  }

  @Test func anICloudOnlyOriginalFallsBackToItsLocalPreview() {
    let result = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: true, allowNetwork: false,
                                          preview: Self.image(2))
    guard case .preview(let got) = result else { Issue.record("expected the preview"); return }
    #expect(got.width == 2)
    #expect(result.isPreview)
    #expect(result.image?.width == 2, "cards and the Indexer read the preview through `image`")
  }

  @Test func aFailedDownloadStillKeepsThePreview() {
    guard case .preview = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: true, allowNetwork: true,
                                                   preview: Self.image(2))
    else { Issue.record("expected the preview"); return }
  }

  @Test func aPreviewCountsOnlyWhenTheFinalCallSaysICloudOrError() {
    // No final image, but PhotoKit gave no reason: a failure, not proof the original is in iCloud.
    guard case .failed = ThumbnailResult.classify(image: nil, isInCloud: false, hasError: false, allowNetwork: false,
                                                  preview: Self.image(2))
    else { Issue.record("expected failed"); return }
    guard case .preview = ThumbnailResult.classify(image: nil, isInCloud: false, hasError: true, allowNetwork: false,
                                                   preview: Self.image(2))
    else { Issue.record("expected the preview"); return }
  }

  @Test func cancellingDropsThePreview() {
    guard case .cancelled = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: false, cancelled: true,
                                                     allowNetwork: false, preview: Self.image(2))
    else { Issue.record("expected cancelled"); return }
  }

  @Test func withoutAPreviewNothingChanges() {
    guard case .inCloud = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: true, allowNetwork: false,
                                                   preview: nil)
    else { Issue.record("expected inCloud"); return }
    #expect(ThumbnailResult.inCloud.image == nil && !ThumbnailResult.inCloud.isPreview)
  }
}
