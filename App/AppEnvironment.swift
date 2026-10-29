import Foundation
import Indexer
import Store

/// What the app is built from. `live()` uses PhotoKit, the real model and Application Support; previews swap in
/// an in-memory store, generated thumbnails and `StubEmbedder` (see `PreviewData`).
struct AppEnvironment {
  var database: AppDatabase
  /// Where `Roll/Index/vectors.egix` lives; nil means Application Support.
  var supportDirectory: URL?
  var library: any LibrarySource
  var access: any LibraryAccess
  var loader: any EmbedderLoader
  var thumbnails: any ThumbnailProvider
  var defaults: UserDefaults
  /// Off in previews: no library sync, no change observer, no RevenueCat.
  var isLive: Bool
  var skipsPaywall = false
}
