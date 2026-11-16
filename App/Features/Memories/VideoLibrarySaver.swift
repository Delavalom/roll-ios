import Foundation
import Photos

/// Saves a finished memory video into the photo library. Additive only: it creates one asset and never touches
/// existing ones. Asks for add-only access (`NSPhotoLibraryAddUsageDescription`) if Roll doesn't have it yet.
enum VideoLibrarySaver {
  enum Failure: Error { case notAllowed }

  static func save(_ url: URL) async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { throw Failure.notAllowed }
    try await PHPhotoLibrary.shared().performChanges {
      _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
    }
  }
}
