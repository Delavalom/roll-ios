import CoreGraphics
import Foundation
import Library
import Signals
import Store

/// The tag pass: labels what each analysed photo shows (Vision scene classification, `SceneClassifier`) so typed search
/// can fuse the labels like words (Find V4, `FindConfig.tags`, `Repositories.tagLabels`). Modelled on the text pass
/// (`TextIndexer`), and run after it, once indexing has drained: the photo pass goes first, so the first index and the
/// taste scan don't wait for it. The candidates are live, analysed photos (videos by their poster frame) not read at
/// `revision`, newest first; the same pass handles new photos and everything indexed before tags existed.
///
/// Throttled: one image at a time, and it waits while the device is `.fair` or warmer (`defaultThermal`). Only local
/// images are read unless `allowNetwork`; photos with none are recorded unread. Cancellation follows the text pass: the
/// image in flight is dropped, everything read before it is committed. It never touches signals, flags or vectors.
public actor TagIndexer {
  private let library: any LibrarySource
  private let classifier: any TagSource
  private let repo: any TagRepository
  private let thermal: ThermalGate
  private let config: TagPassConfig

  /// The classifier's revision and the image size: changing either reads every photo again.
  public nonisolated let revision: String

  /// Pauses from `.fair` (polls every 5 s), like the text pass.
  public static var defaultThermal: ThermalGate { ThermalGate(pausesAt: .fair) }

  private var chain: Task<Void, Never>?
  private var running: [UUID: Task<TagReport, Error>] = [:]

  public init(library: any LibrarySource, classifier: any TagSource, repo: any TagRepository,
              thermal: ThermalGate = TagIndexer.defaultThermal, config: TagPassConfig = TagPassConfig()) {
    self.library = library
    self.classifier = classifier
    self.repo = repo
    self.thermal = thermal
    self.config = config
    revision = "\(classifier.revision)@\(config.side)"
  }

  /// Photos a `run(allowNetwork:)` would read now.
  public func pendingCount(allowNetwork: Bool = false) async throws -> Int {
    try await repo.tagCandidateCount(revision: revision, retryUnread: allowNetwork)
  }

  /// Classifies up to `limit` candidates (nil: all), newest first. Runs one after another: a call made during a run
  /// starts when it ends. Throws `CancellationError` when the caller is cancelled or on `cancel()`.
  @discardableResult
  public func run(limit: Int? = nil, allowNetwork: Bool = false) async throws -> TagReport {
    try Task.checkCancellation()
    let previous = chain
    let task = Task<TagReport, Error> {
      await previous?.value
      return try await self.pass(limit: limit, allowNetwork: allowNetwork)
    }
    chain = Task { _ = await task.result }
    let id = UUID()
    running[id] = task
    defer { running[id] = nil }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  /// Stops every active and waiting run (each commits what it read).
  public func cancel() {
    for task in running.values { task.cancel() }
  }

  private func pass(limit: Int?, allowNetwork: Bool) async throws -> TagReport {
    try Task.checkCancellation()
    let ids = try await repo.tagCandidateIds(revision: revision, retryUnread: allowNetwork, limit: limit ?? Int.max)
    var report = TagReport()
    var buffer: [TagFields] = []
    do {
      for id in ids {
        try Task.checkCancellation()
        report.thermalPolls += try await thermal.waitUntilOK()
        let loaded = await load(id, allowNetwork: allowNetwork)
        if case .cancelled = loaded, Task.isCancelled { throw CancellationError() }
        if let image = usable(loaded) {
          if let labels = try await classifier.classify(image) {
            report.read += 1
            if !labels.isEmpty { report.tagged += 1 }
            buffer.append(TagFields(
              id: id, labels: labels.map { TagLabel(label: $0.identifier, confidence: Double($0.confidence)) },
              revision: revision, side: max(image.width, image.height)))
          } else {
            report.failed += 1
            buffer.append(unread(id))
          }
        } else {
          switch loaded {
          case .failed, .cancelled: report.failed += 1
          default: report.unread += 1
          }
          buffer.append(unread(id))
        }
        if buffer.count >= config.commitEvery {
          try await commit(buffer)
          buffer = []
        }
      }
      try await commit(buffer)
    } catch {
      do { try await commit(buffer) } catch {
        IndexerLog.logger.error("tag commit after an interrupted pass failed: \(String(describing: error))")
      }
      throw error
    }
    return report
  }

  private func unread(_ id: String) -> TagFields {
    TagFields(id: id, labels: [], revision: revision, side: nil)
  }

  /// Its own task, so a cancelled pass still saves what it read.
  private func commit(_ items: [TagFields]) async throws {
    guard !items.isEmpty else { return }
    let repo = repo
    try await Task { try await repo.commitTags(items) }.value
  }

  /// The image at `config.side`: on the device first; with `allowNetwork`, what didn't come is asked for again with
  /// the network. A local preview is kept over a failed download.
  private func load(_ id: String, allowNetwork: Bool) async -> ThumbnailResult {
    let offline = await library.thumbnails(ids: [id], side: config.side, allowNetwork: false)[id] ?? .failed
    if case .image = offline { return offline }
    guard allowNetwork, !Task.isCancelled else { return offline }
    let online = await library.thumbnails(ids: [id], side: config.side, allowNetwork: true)[id] ?? .failed
    if case .image = online { return online }
    return offline.image != nil ? offline : online
  }

  /// A full image, or a local preview at least `minimumPreviewSide` long.
  private func usable(_ result: ThumbnailResult) -> CGImage? {
    switch result {
    case .image(let image): image
    case .preview(let image) where max(image.width, image.height) >= config.minimumPreviewSide: image
    default: nil
    }
  }
}
