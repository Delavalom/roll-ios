import CoreGraphics
import Foundation
import Library
import Signals
import Store

// The Indexer's inputs and outputs as protocols, so tests inject fakes. Production conformances are the
// real types: `PhotoLibrary` (iOS), `SignalExtractor`, `Repositories` and `VectorStore`.

/// Read access to the photo library (`PhotoLibrary`).
public protocol LibrarySource: Sendable {
  /// Every image and video, newest first, with `uti == nil`.
  func fetchAll() async -> [AssetSnapshot]
  /// Snapshots for these ids only (also without UTIs). Ids that are gone are left out.
  func snapshots(ids: [String]) async -> [AssetSnapshot]
  /// UTIs of the original resources. Called only for ids new to the Store.
  func utis(for ids: [String]) async -> [String: String]
  func thumbnails(ids: [String], side: Int, allowNetwork: Bool) async -> [String: ThumbnailResult]
  func videoFrame(id: String, at fraction: Double, side: Int, allowNetwork: Bool) async -> ThumbnailResult
}

/// Vision signals (`SignalExtractor`). Images go through one at a time.
public protocol SignalSource: Sendable {
  /// Called once per 200-asset batch.
  func refreshPolicy()
  func extract(_ image: CGImage) async throws(CancellationError) -> AssetSignals
}

/// The Store calls the Indexer makes (`Repositories`). Each writer owns its columns (see AGENTS.md).
public protocol IndexRepository: Sendable {
  func upsertAssets(_ records: [AssetRecord]) async throws
  func assetRefs(ids: [String]?) async throws -> [AssetRef]
  func markDeleted(_ ids: [String], at date: Date) async throws
  func pendingAssetIds(includingEmbedding: Bool, includingCloudOnly: Bool) async throws -> [String]
  func pendingAssetCount(includingEmbedding: Bool, includingCloudOnly: Bool) async throws -> Int
  func assets(ids: [String]) async throws -> [AssetRecord]
  /// Live rows analysed from a local preview, newest first (the "Improve with iCloud originals" work).
  func previewAssetIds() async throws -> [String]
  func typeLookupCandidates(minPixels: Int, excludingSubtypes: Int, limit: Int) async throws -> [String]
  func updateTypes(_ updates: [(id: String, uti: String, estBytes: Int64)]) async throws
  func commitSignals(_ updates: [SignalFields]) async throws
  func recordFailedAttempts(ids: [String]) async throws
  func markEmbedded(ids: [String]) async throws
  func clearEmbedded(ids: [String]) async throws -> Int
  func deletedEmbeddedIds() async throws -> [String]
  func resetForContentChange(ids: [String]) async throws -> Int
}

/// Where vectors go (`VectorStore`). Flushes always run `upsert` → `save` → `markEmbedded`.
public protocol VectorSink: Sendable {
  var dimensions: Int { get }
  var revision: String { get }
  var count: Int { get async }
  func reserve(_ expectedCount: Int) async
  func upsert(_ batch: [(id: String, vector: [Float])]) async throws
  func remove(ids: [String]) async throws
  func save() async throws
}

extension SignalExtractor: SignalSource {}
extension Repositories: IndexRepository {}
extension VectorStore: VectorSink {}

#if canImport(Photos) && os(iOS)
extension PhotoLibrary: LibrarySource {}
#endif
