import Foundation
import Library
import Squish
import Store

/// Finds the videos Squish would refuse at export time (Dolby Vision, ProRes, Apple Log) before they can be selected,
/// by reading each local candidate's track format, in the background. Results are stored per asset and hold while the
/// asset is unchanged: a pass in `videoProbe` (the video may then start selected), a refusal in `squishRefusal` (it
/// leaves the list and the savings). Videos only in iCloud aren't probed (nothing is downloaded). One probing task at
/// a time: a call made while one runs waits for it instead of starting another.
///
/// Each probe gets `timeout`. One that doesn't answer records nothing (the video isn't selected by default) and isn't
/// probed again until the next launch; after `maxConsecutiveTimeouts` in a row the pass stops (PhotoKit isn't
/// answering).
public actor SquishFormatScreen {
  /// What one pass did.
  public struct Screening: Sendable, Equatable {
    /// Newly refused (Dolby Vision, ProRes, Apple Log).
    public var refused: Int
    /// Results stored: passes and refusals.
    public var recorded: Int
    public var timedOut: Int
    public init(refused: Int = 0, recorded: Int = 0, timedOut: Int = 0) {
      self.refused = refused; self.recorded = recorded; self.timedOut = timedOut
    }
  }

  /// Opening a local video and reading its track formats takes well under a second.
  public static let defaultTimeout: Duration = .seconds(10)
  public static let maxConsecutiveTimeouts = 3

  private let probe: any VideoFormatProbing
  private let repositories: Repositories
  private let timeout: Duration
  /// Probed with an answer during this launch (an unreadable video is tried again on the next pass).
  private var probed: Set<String> = []
  /// Probes that timed out during this launch: tried again next launch.
  private var timedOut: Set<String> = []
  private var running: Task<Screening, Error>?

  public init(probe: any VideoFormatProbing, repositories: Repositories,
              timeout: Duration = SquishFormatScreen.defaultTimeout) {
    self.probe = probe
    self.repositories = repositories
    self.timeout = timeout
  }

  /// Probes the local video candidates without a stored result. Returns how many were newly refused.
  @discardableResult
  public func run() async throws -> Int {
    try await screen().refused
  }

  /// One pass over `catalog` (a fresh `SquishCatalog.load` when nil; pass one the caller just loaded to save a read).
  @discardableResult
  public func screen(catalog: SquishCatalog? = nil) async throws -> Screening {
    if let running { return try await running.value }
    let task = Task { try await self.probeAll(catalog) }
    running = task
    defer { running = nil }
    return try await task.value
  }

  private func probeAll(_ given: SquishCatalog?) async throws -> Screening {
    let catalog: SquishCatalog
    if let given { catalog = given } else { catalog = try await SquishCatalog.load(repositories: repositories, keep4K: false) }
    let passed = try await repositories.passedVideoProbes()
    var screening = Screening(), inARow = 0
    let probe = probe
    for item in catalog.items where item.kind == .video && !passed.contains(item.assetID)
      && !probed.contains(item.assetID) && !timedOut.contains(item.assetID) {
      try Task.checkCancellation()
      // `cloudOnly`: the original isn't known to be on this iPhone (not checked yet counts as iCloud).
      guard !catalog.cloudOnly.contains(item.assetID) else { continue }
      let id = item.assetID
      let answer = await Deadline.answer(within: timeout) { await probe.probe(for: id) }
      try Task.checkCancellation()
      guard let answer else {
        timedOut.insert(id)
        screening.timedOut += 1
        inARow += 1
        if inARow >= Self.maxConsecutiveTimeouts { break }
        continue
      }
      inARow = 0
      guard let result = answer else { continue }
      probed.insert(id)
      screening.recorded += 1
      switch result.verdict {
      case .squishable:
        // What the file measured lets the plan drop a video that's already compact (`SquishPlanner.offer`).
        try await repositories.recordVideoProbePassed(assetId: id, facts: result.facts ?? VideoProbeFacts())
      case .dolbyVision:
        try await repositories.recordSquishRefusal(assetId: id, reason: SquishRefusal.hdrVideoKept)
        screening.refused += 1
      case .proRes, .appleLog:
        try await repositories.recordSquishRefusal(assetId: id, reason: SquishRefusal.text(for: .unsupportedFormat))
        screening.refused += 1
      }
    }
    return screening
  }
}
