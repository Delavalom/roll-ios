import CoreGraphics
import Foundation
import Library
import Signals
import Store

/// The text pass: reads the words in gated images (screenshots and Vision `isUtility` photos, `TextGate`) so typed
/// search can find them (`Repositories.keywordCoverage`). It runs after the signal pass, as its own pass, because:
/// - it needs its own image: the Indexer's 300 px analysis thumbnail is too small to read (see `TextPassConfig.side`);
/// - reading costs about a quarter of a second per image on an M1 Pro, against about 54 ms per asset for the whole
///   signal and embedding pass on the phone, so inside the signal pass it would slow the (thermal-bound) first index
///   and the onboarding taste scan, the moments the person is waiting.
/// The same pass handles new images and everything analysed before v10 (a backfill): the candidates are gated, analysed
/// images without text at this `revision`, newest first.
///
/// Throttled: one image at a time, and it waits while the device is `.fair` or warmer (`defaultThermal`; the Indexer
/// waits only from `.serious`). The app runs it once the Indexer is idle, and cancels it with the Indexer.
/// Cancellation follows the Indexer's rules: the image in flight is dropped, everything read before it is committed (in
/// a task of its own, so the cancellation can't stop the write). It never touches signals, flags or vectors.
public actor TextIndexer {
  private let library: any LibrarySource
  private let reader: any TextSource
  private let repo: any TextRepository
  private let thermal: ThermalGate
  private let config: TextPassConfig

  /// The reader's revision and the image size: changing either reads every gated image again.
  public nonisolated let revision: String

  /// Pauses from `.fair` (polls every 5 s).
  public static var defaultThermal: ThermalGate { ThermalGate(pausesAt: .fair) }

  private var chain: Task<Void, Never>?
  private var running: [UUID: Task<TextReport, Error>] = [:]

  public init(library: any LibrarySource, reader: any TextSource, repo: any TextRepository,
              thermal: ThermalGate = TextIndexer.defaultThermal, config: TextPassConfig = TextPassConfig()) {
    self.library = library
    self.reader = reader
    self.repo = repo
    self.thermal = thermal
    self.config = config
    revision = "\(reader.revision)@\(config.side)"
  }

  /// Images a `run(allowNetwork:)` would read now.
  public func pendingCount(allowNetwork: Bool = false) async throws -> Int {
    try await repo.textCandidateCount(revision: revision, retryUnread: allowNetwork)
  }

  /// Reads up to `limit` candidates (nil: all), newest first. Without `allowNetwork` only images on the device are
  /// read and the rest are recorded unread; with it (Wi-Fi, the app decides) unread images are tried again and may be
  /// downloaded. Runs one after another: a call made during a run starts when it ends. Throws `CancellationError` when
  /// the caller is cancelled or on `cancel()`.
  @discardableResult
  public func run(limit: Int? = nil, allowNetwork: Bool = false) async throws -> TextReport {
    try Task.checkCancellation()
    let previous = chain
    let task = Task<TextReport, Error> {
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

  private func pass(limit: Int?, allowNetwork: Bool) async throws -> TextReport {
    try Task.checkCancellation()
    let ids = try await repo.textCandidateIds(revision: revision, retryUnread: allowNetwork, limit: limit ?? Int.max)
    var report = TextReport()
    var buffer: [TextFields] = []
    do {
      for id in ids {
        try Task.checkCancellation()
        report.thermalPolls += try await thermal.waitUntilOK()
        let loaded = await load(id, allowNetwork: allowNetwork)
        if case .cancelled = loaded, Task.isCancelled { throw CancellationError() }
        if let image = usable(loaded) {
          if let text = try await reader.recognize(image) {
            report.read += 1
            if !TextTerms.terms(text).isEmpty { report.withWords += 1 }
            buffer.append(TextFields(id: id, text: text, revision: revision, side: max(image.width, image.height)))
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
        IndexerLog.logger.error("text commit after an interrupted pass failed: \(String(describing: error))")
      }
      throw error
    }
    return report
  }

  private func unread(_ id: String) -> TextFields {
    TextFields(id: id, text: "", revision: revision, side: nil)
  }

  /// Its own task, so a cancelled pass still saves what it read.
  private func commit(_ items: [TextFields]) async throws {
    guard !items.isEmpty else { return }
    let repo = repo
    try await Task { try await repo.commitText(items) }.value
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

  /// A full image at the requested size (or the original, if smaller), or a preview about that big.
  private func usable(_ result: ThumbnailResult) -> CGImage? {
    switch result {
    case .image(let image): image
    case .preview(let image) where max(image.width, image.height) >= config.minimumPreviewSide: image
    default: nil
    }
  }
}
