import Commit
import Embedding
import EmbeddingGemma
import Entitlements
import Foundation
import Indexer
import Library
import ModelInstall
import Monitor
import Observation
import Overview
import Ranking
import Signals
import Squish
import SquishBridge
import Store
import SwiftUI
import Synchronization
import os

extension AppModel {
  // MARK: - Model

  /// Loads the model (downloading it if needed) and attaches it. Safe to call again: a retry after a failure.
  func loadModel(allowCellular: Bool = false) {
    guard modelTask == nil, engine == nil else { return }
    modelState = .loading(nil)
    modelAttempt += 1
    let attempt = modelAttempt
    let loader = environment.loader, indexer = indexer, database = database
    let base = environment.supportDirectory, opened = OpenedStore()
    modelTask = Task { [weak self] in
      do {
        let embedder = try await loader.load(allowCellular: allowCellular) { step in
          Task { @MainActor in self?.modelStepped(step, attempt: attempt) }
        }
        try Task.checkCancellation()
        await self?.prepareIfNeeded(embedder, attempt: attempt)
        try Task.checkCancellation()
        try await indexer.setEmbedder(embedder) { revision, dimensions in
          let store = try await VectorStore(url: try VectorStore.defaultURL(in: base), dimensions: dimensions,
                                            revision: revision, database: database)
          opened.set(store)
          return store
        }
        guard let store = opened.get() else { throw CancellationError() }
        let repositories = Repositories(database)
        self?.attach(SwipefileEngine(repositories: repositories, vectors: store, embedder: embedder,
                                     keywordCoverage: { try await repositories.keywordCoverage(terms: $0) }))
      } catch {
        self?.modelFailed(error, attempt: attempt)
      }
    }
  }

  /// The person chose to download now on mobile data or in Low Data Mode (only offered while waiting): the waiting
  /// attempt stops, keeping what it downloaded, and a new one resumes it on any network.
  ///
  /// Deliberately not persisted: the choice holds for this attempt only. After a relaunch, a retry or a failure the
  /// download is Wi-Fi-only again and the person is asked again, so a one-off "yes" on a good plan never turns into
  /// 359 MB on roaming later.
  func downloadModelAnyway() {
    guard engine == nil, case .waiting = modelState else { return }
    modelTask?.cancel()
    modelTask = nil
    loadModel(allowCellular: true)
  }

  private func modelStepped(_ step: InstallStep, attempt: Int) {
    guard attempt == modelAttempt, engine == nil else { return }
    switch step {
    case .waiting(let reason, let total):
      modelState = .waiting(reason, totalBytes: total)
    case .downloading(let done, let total):
      // Waiting stays until bytes arrive: a "0 of 359 MB" row would hide the mobile-data choice.
      if case .waiting = modelState, done == 0 { return }
      let progress = ModelProgress(completedBytes: done, totalBytes: total)
      if case .loading(let previous?) = modelState, previous.completedBytes > done { return }
      modelState = .loading(progress)
    case .unpacking, .activating:
      modelState = .loading(nil)
    }
  }

  /// Compiles the model's functions one at a time before indexing starts, when they may not be compiled yet: the first
  /// launch of this model revision in this app build and data container (`SearchPreparation.marker`). iOS keeps the compiled functions across launches (16/16 warm
  /// on an iPhone 13 Pro Max, two of them after 13.4 h and 12.3 h), but an install or an update moves the app's
  /// container, which changes their cache key, so each compiles again: 45–230 s and about 1.5 GB of memory each
  /// (embeddinggemma-coreml docs/investigations/2026-10-27-ane-cache.md, s6). One at a time keeps that peak to one
  /// compile; indexing would otherwise compile them as photos reach each bucket while search compiles others.
  /// Later launches skip this: each function loads from the cache on first use (about 3.5 s).
  ///
  /// Below `EmbeddingGemma.prewarmReserve` of free space it stops (`searchStorageLow`): a compile could push iOS into
  /// deleting the cache. Nothing is lost: what isn't loaded loads on first use, and the next launch tries again.
  private func prepareIfNeeded(_ embedder: any Embedder, attempt: Int) async {
    let info = Bundle.main.infoDictionary ?? [:]
    let marker = SearchPreparation.marker(revision: embedder.revision,
                                          version: info["CFBundleShortVersionString"] as? String,
                                          build: info["CFBundleVersion"] as? String, container: NSHomeDirectory())
    guard environment.defaults.string(forKey: Self.searchPreparedKey) != marker else { return }
    do {
      try await embedder.prepare { done, total in
        Task { @MainActor [weak self] in self?.modelPreparing(done: done, total: total, attempt: attempt) }
      }
      environment.defaults.set(marker, forKey: Self.searchPreparedKey)
      searchStorageLow = false
    } catch EmbeddingGemmaError.insufficientStorage {
      searchStorageLow = true
    } catch {
      // A function that fails even after the package's retries loads, and retries, on first use instead.
      Logger(subsystem: "com.delavalom.roll", category: "model")
        .error("preparing the model failed: \(String(describing: error))")
    }
  }

  private func modelPreparing(done: Int, total: Int, attempt: Int) {
    guard attempt == modelAttempt, engine == nil else { return }
    modelState = .preparing(done: done, total: total)
  }

  private func attach(_ engine: SwipefileEngine) {
    self.engine = engine
    modelState = .ready
    modelTask = nil
    bumpLibrary()
  }

  private func modelFailed(_ error: any Error, attempt: Int) {
    guard attempt == modelAttempt else { return }  // superseded: the new attempt owns the state
    modelState = .unavailable(ModelIssue(error))
    modelTask = nil
  }
}

/// The store `setEmbedder` opened, handed back from its `@Sendable` closure.
private final class OpenedStore: Sendable {
  private let store = Mutex<VectorStore?>(nil)
  func set(_ value: VectorStore) { store.withLock { $0 = value } }
  func get() -> VectorStore? { store.withLock { $0 } }
}
