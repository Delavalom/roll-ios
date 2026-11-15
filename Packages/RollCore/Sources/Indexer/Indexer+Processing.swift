import CoreGraphics
import Embedding
import Foundation
import Library
import os
import Signals
import Store
import Synchronization

extension Indexer {
  // MARK: - Processing

  func reserveIfLarge(incoming: Int) async {
    guard let embedding else { return }
    let stored = await embedding.vectors.count
    let needed = stored + incoming
    guard incoming > max(config.reserveThreshold, stored / 10), needed > reservedCapacity else { return }
    await embedding.vectors.reserve(needed)
    reservedCapacity = needed
  }

  /// One page, in thumbnail groups: the next group loads while this one goes through Vision and the
  /// embedder, one asset at a time.
  func process(_ records: [AssetRecord], allowNetwork: Bool, runId: Int, base: Int, total: Int,
                       state: inout RunState) async throws {
    var processed = base
    let work = records.filter { needsWork($0) || isUpgrade($0, state) }
    // Rows that need nothing any more (handled since the snapshot) count as processed.
    state.report.processed += records.count - work.count
    processed += records.count - work.count
    let groups = stride(from: 0, to: work.count, by: config.thumbnailChunk).map {
      Array(work[$0..<min($0 + config.thumbnailChunk, work.count)])
    }
    var next = groups.first.map { loadThumbnails($0, allowNetwork: allowNetwork) }
    for group in groups.indices {
      guard let current = next else { break }
      let loaded = await withTaskCancellationHandler { await current.value } onCancel: { current.cancel() }
      let thumbnails = loaded.results
      next = group + 1 < groups.count ? loadThumbnails(groups[group + 1], allowNetwork: allowNetwork) : nil
      do {
        for record in groups[group] {
          try Task.checkCancellation()
          try await index(record, thumbnail: thumbnails[record.id] ?? .failed,
                          downloaded: loaded.downloaded.contains(record.id), runId: runId, state: &state)
          state.report.processed += 1
          processed += 1
          publish(IndexProgress(runId: runId, processed: processed, total: total, phase: .indexing))
        }
      } catch {
        next?.cancel()
        throw error
      }
    }
  }

  func isUpgrade(_ record: AssetRecord, _ state: RunState) -> Bool {
    !record.deleted && record.source == .preview && state.upgrading.contains(record.id)
  }

  func needsWork(_ record: AssetRecord) -> Bool {
    !record.deleted && (!record.signalsDone || (embedding != nil && !record.embedded))
  }

  /// Thumbnails for a group, and which of them came from a download.
  struct Loaded: Sendable {
    var results: [String: ThumbnailResult] = [:]
    var downloaded: Set<String> = []
  }

  /// Always asks with network access off first: that answer is the only evidence of where an original is. With
  /// `allowNetwork`, what didn't come back as a full image is then requested again with the network; a full image from
  /// that second request is a download (`downloaded`). If the download fails, an offline preview still counts.
  nonisolated func loadThumbnails(_ records: [AssetRecord], allowNetwork: Bool) -> Task<Loaded, Never> {
    let library = library
    let side = config.thumbnailSide
    let fraction = config.videoFrameFraction
    let photos = records.filter { $0.mediaType != MediaKind.video }.map(\.id)
    let videos = records.filter { $0.mediaType == MediaKind.video }.map(\.id)
    @Sendable func fetch(_ photos: [String], _ videos: [String], network: Bool) async -> [String: ThumbnailResult] {
      var results = photos.isEmpty ? [:] : await library.thumbnails(ids: photos, side: side, allowNetwork: network)
      for id in videos {
        results[id] = Task.isCancelled
          ? .cancelled : await library.videoFrame(id: id, at: fraction, side: side, allowNetwork: network)
      }
      return results
    }
    return Task {
      var loaded = Loaded(results: await fetch(photos, videos, network: false))
      guard allowNetwork, !Task.isCancelled else { return loaded }
      func needsDownload(_ id: String) -> Bool {
        switch loaded.results[id] {
        case .image?, .cancelled?: false
        default: true
        }
      }
      let retry = (photos.filter(needsDownload), videos.filter(needsDownload))
      guard !retry.0.isEmpty || !retry.1.isEmpty else { return loaded }
      for (id, result) in await fetch(retry.0, retry.1, network: true) {
        if case .image = result {
          loaded.results[id] = result
          loaded.downloaded.insert(id)
        } else if loaded.results[id]?.isPreview != true {
          loaded.results[id] = result  // keep an offline preview over a failed download
        }
      }
      return loaded
    }
  }

  func index(_ record: AssetRecord, thumbnail: ThumbnailResult, downloaded: Bool, runId: Int,
                     state: inout RunState) async throws {
    let target = embedding
    let upgrade = isUpgrade(record, state)
    if upgrade, !(thumbnail.image != nil && !thumbnail.isPreview) {
      // The full image didn't come (still only the preview, or failed): keep the row as it is.
      if case .cancelled = thumbnail, Task.isCancelled { throw CancellationError() }
      failedUpgrades[record.id, default: 0] += 1  // our own cancel above isn't an attempt
      return
    }
    let needsSignals = !record.signalsDone || upgrade
    let needsVector = target != nil && (!record.embedded || upgrade)

    let image: CGImage
    let fromPreview: Bool
    switch thumbnail {
    case .cancelled where Task.isCancelled:
      throw CancellationError()  // our own cancellation: stop, record nothing
    case .failed, .cancelled:
      // A cancel we didn't ask for (PhotoKit gave up) is a failed load like any other.
      state.report.failed += 1
      failureBuffer.append(record.id)
      return
    case .inCloud:
      state.report.cloudOnly += 1
      state.cloudSkipped.insert(record.id)
      signalBuffer.append(SignalFields(keeping: record, cloudOnly: true))
      return
    case .image(let cgImage):
      image = cgImage
      fromPreview = false
    case .preview(let cgImage):
      image = cgImage
      fromPreview = true
    }
    // Where the original is, from the offline request only: a preview or a download means iCloud; a full image that
    // came without the network means this iPhone.
    let cloudOnly = fromPreview || downloaded
    let source: AnalysisSource = fromPreview ? .preview : .full
    let previewSide = max(image.width, image.height)  // the analysed image's size, preview or full

    if thermal.isThrottled {
      publish(IndexProgress(runId: runId, processed: progress.processed, total: progress.total, phase: .thermalPause))
      state.report.thermalPolls += try await thermal.waitUntilOK()
      publish(IndexProgress(runId: runId, processed: progress.processed, total: progress.total, phase: .indexing))
    }

    let signals = signals
    async let computed = Self.extract(signals, image, if: needsSignals)
    async let vector = Self.embed(target?.embedder, image, if: needsVector)
    let embedded = await vector
    let fields = try await computed
    try Task.checkCancellation()  // a cancelled asset is discarded whole

    if let fields {
      state.report.signalsComputed += 1
      if fromPreview { state.report.previews += 1 }
      if upgrade { state.report.upgraded += 1 }
      signalBuffer.append(SignalFields(id: record.id, computed: fields, cloudOnly: cloudOnly, source: source,
                                       previewSide: previewSide))
    } else if record.cloudOnly != cloudOnly {
      signalBuffer.append(SignalFields(keeping: record, cloudOnly: cloudOnly))
    }
    switch embedded {
    case .vector(let values):
      // Dropped if the embedder was swapped meanwhile: it belongs to the old index.
      guard let target, target.generation == embedding?.generation else { break }
      guard values.count == target.vectors.dimensions else {
        IndexerLog.logger.error("embedder returned \(values.count) values, expected \(target.vectors.dimensions)")
        state.report.embedFailures += 1
        break
      }
      state.report.embedded += 1
      if vectorBuffer == nil { vectorBuffer = VectorBatch(generation: target.generation, sink: target.vectors, items: []) }
      vectorBuffer?.items.append((id: record.id, vector: values))
    case .failed:
      state.report.embedFailures += 1
    case .skipped:
      break
    }
  }

  enum EmbedOutcome: Sendable {
    case vector([Float]), failed, skipped
  }

  static func extract(_ source: any SignalSource, _ image: CGImage, if needed: Bool)
    async throws(CancellationError) -> AssetSignals? {
    guard needed else { return nil }
    return try await source.extract(image)
  }

  static func embed(_ embedder: (any Embedder)?, _ image: CGImage, if needed: Bool) async -> EmbedOutcome {
    guard needed, let embedder else { return .skipped }
    do {
      return .vector(try await embedder.embed(image: image))
    } catch {
      if !Task.isCancelled { IndexerLog.logger.error("embedding failed: \(String(describing: error))") }
      return .failed
    }
  }
}
