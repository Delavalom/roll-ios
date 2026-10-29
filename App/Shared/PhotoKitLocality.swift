import Library
import Overview
import Photos
import Store

/// `LocalityChecking` over PhotoKit: asks for the primary resource's data with network access off. The first chunk
/// proves the original is on the device, so the request is cancelled right there (nothing more is read); an error
/// means it is only in iCloud. Read-only; never downloads. Cancellable (`OneShot`): when `LocalityScanner` gives up
/// on a request that doesn't answer, the cancel reaches PhotoKit and the answer is nil (not checked), never "on the
/// device".
struct PhotoKitLocality: LocalityChecking {
  func isLocal(_ record: AssetRecord) async -> Bool? { await Self.isLocal(id: record.id) }

  /// The same check by asset id (DEBUG `-QARestock` uses it on QA album members that have no Store row yet).
  static func isLocal(id: String) async -> Bool? {
    let fetch = PHFetchOptions()
    fetch.includeHiddenAssets = true
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: fetch).firstObject else { return nil }
    let resources = PHAssetResource.assetResources(for: asset)
    guard let primary = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first else {
      return nil
    }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = false
    let manager = PHAssetResourceManager.default()
    let shot = OneShot<Bool?>(cancelledValue: nil)
    return await shot.run { shot in
      let request = manager.requestData(for: primary, options: options, dataReceivedHandler: { _ in
        // On the device: answer, then stop reading (the cancel's own nil comes second and is ignored).
        shot.resolve(true)
        shot.cancel()
      }, completionHandler: { error in
        shot.resolve(error == nil)  // a completion after our own cancel is ignored
      })
      shot.setCancelAction { manager.cancelDataRequest(request) }
    }
  }
}
