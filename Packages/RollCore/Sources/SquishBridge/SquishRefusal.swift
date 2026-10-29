import Commit
import Foundation
import Squish
import Store

/// Why an item wasn't squished, in words the UI shows.
public enum SquishRefusal: Sendable, Equatable {
  /// Limited Photos access: "Squish needs Full Access to Photos", with a Settings link.
  case needsFullAccess
  /// The item can't be squished in v1 (format or kind); listed under "Not squishable yet" with the reason.
  case notSquishable(String)
  /// The original is only in iCloud and downloads are off.
  case needsDownload
  case notEnoughSpace
  /// Squishing ran but didn't work out (not smaller, a check failed, ...). The original is untouched.
  case failed(String)

  public static let fullAccessMessage = "Squish needs Full Access to Photos"
  /// Dolby Vision videos (an iPhone's default HDR recording): v1 leaves them as they are.
  public static let hdrVideoKept = "HDR video kept as is"
  /// A probed video Squish couldn't make at least `SquishPlanner.minimumSavingsFraction` smaller.
  public static let alreadyCompactHEVC = "Already compact (HEVC)"
  public static let alreadyCompact = "Already compact"

  public static func classify(_ error: any Error) -> SquishRefusal {
    if let runner = error as? SquishRunnerError, runner == .needsFullAccess { return .needsFullAccess }
    #if DEBUG
    if let qa = error as? QAScopeViolation { return .failed(qa.description) }  // device QA (-QAAlbum) refusals
    #endif
    guard let replace = error as? ReplaceError else { return .failed("Something went wrong.") }
    switch replace {
    case .needsFullAccess: return .needsFullAccess
    case .ineligible(let reason): return .notSquishable(text(for: reason))
    case .squish(.ineligible(let reason)): return .notSquishable(text(for: reason))
    case .squish(.notSmaller): return .failed("It wouldn't get meaningfully smaller.")
    case .squish(.unsupported): return .failed("This iPhone can't encode that format.")
    case .needsDownload: return .needsDownload
    case .insufficientSpace: return .notEnoughSpace
    case .assetNotFound: return .failed("It's no longer in your library.")
    case .verificationFailed: return .failed("The smaller copy didn't pass its checks, so the original was kept.")
    case .createFailed(let underlying) where underlying is SquishJournalError:
      return .failed("A copy from an earlier squish is still waiting. Finish or remove it on Home first.")
    default: return .failed("Something went wrong. The original is untouched.")
    }
  }

  public static func text(for reason: IneligibilityReason) -> String {
    switch reason {
    case .unsupportedFormat: "This format can't be squished yet (HEIC, RAW/ProRAW, ProRes, Log or Dolby Vision)"
    case .unsupportedMediaType: "Not a photo or video"
    case .notInUserLibrary: "From a shared album or synced from a computer"
    case .burst: "Part of a burst"
    case .spatialMedia: "Spatial photo or video"
    case .depthEffect: "Portrait photo with depth"
    case .livePhoto: "Live Photo"
    case .animated: "Animated image"
    case .slowMotion: "Slow-motion video"
    case .cinematic: "Cinematic video"
    case .edited: "Edited (squishing would lose the edit history)"
    case .multiResource: "Has more than one original (like RAW+JPEG)"
    case .multiFrame: "Holds more than one frame"
    case .auxiliaryDataNotPreserved: "Has extra image data that wouldn't carry over"
    case .colorSpaceChanged: "HDR or wide-colour video that would change colour"
    }
  }

  /// Why a large photo with this UTI isn't offered, or nil when its format is squishable.
  public static func formatReason(uti: String?) -> String? {
    guard let uti, !uti.isEmpty, !SquishEligibility.photoFormats.contains(uti) else { return nil }
    switch uti {
    case "public.heic", "public.heif": return "Already compressed (HEIC)"
    case "com.adobe.raw-image", "public.camera-raw-image", "com.apple.raw-image":
      return "RAW or ProRAW photo (squishing would lose the raw data)"
    default: return "This format can't be squished yet"
    }
  }
}

/// A big item the Squish screen lists under "Not squishable yet", with why.
public struct NotSquishable: Sendable, Equatable, Identifiable {
  public let assetID: String
  public let estimatedBytes: Int64
  public let reason: String
  public var id: String { assetID }

  public init(assetID: String, estimatedBytes: Int64, reason: String) {
    self.assetID = assetID; self.estimatedBytes = estimatedBytes; self.reason = reason
  }
}

/// The Squish screen's data: what's worth squishing, and the large photos refused for their format.
public struct SquishCatalog: Sendable, Equatable {
  /// Most bytes first.
  public var items: [SquishPlanItem] = []
  public var notSquishable: [NotSquishable] = []
  /// Items whose original is only in iCloud (they need a download).
  public var cloudOnly: Set<String> = []
  /// Dolby Vision videos found before selection (`SquishFormatScreen`): kept as they are, listed with a count.
  public var hdrKept: [NotSquishable] = []
  /// What the screen selects by default: offered items whose original is on this iPhone, largest first.
  public var defaultSelection: [String] = []

  public init(items: [SquishPlanItem] = [], notSquishable: [NotSquishable] = [], cloudOnly: Set<String> = [],
              hdrKept: [NotSquishable] = [], defaultSelection: [String] = []) {
    self.items = items; self.notSquishable = notSquishable; self.cloudOnly = cloudOnly
    self.hdrKept = hdrKept; self.defaultSelection = defaultSelection
  }

  /// Whether the item can be squished with this download choice: an original only in iCloud needs downloads allowed.
  public func canSquish(_ assetID: String, downloadsAllowed: Bool) -> Bool {
    downloadsAllowed || !cloudOnly.contains(assetID)
  }

  /// What a run would attempt from `selected`, most bytes first: offered items only and, while downloads are off,
  /// none whose original is only in iCloud (the run would refuse them with `needsDownload`). The screen's count,
  /// savings and queue all come from this, so the promise matches the run.
  public func runnable(_ selected: Set<String>, downloadsAllowed: Bool) -> [SquishPlanItem] {
    items.filter { selected.contains($0.assetID) && canSquish($0.assetID, downloadsAllowed: downloadsAllowed) }
  }

  /// What tapping "Squish N items" does. `onWiFi` is checked only when downloads are allowed (Wi-Fi, not expensive):
  /// without it nothing downloads, so iCloud items drop out of the run; when nothing else is left, the screen says Wi-Fi
  /// is needed instead of starting an empty run.
  public func start(_ selected: Set<String>, downloadsAllowed: Bool, onWiFi: Bool) -> SquishStart {
    let network = downloadsAllowed && onWiFi
    let ids = runnable(selected, downloadsAllowed: network).map(\.assetID)
    if !ids.isEmpty { return .run(ids: ids, allowNetwork: network) }
    return runnable(selected, downloadsAllowed: downloadsAllowed).isEmpty ? .nothing : .blocked(.needsWiFi)
  }

  /// Pure. `excluding` is `Repositories.journaledCopyIDs()`: copies Roll made itself are never offered. `refusals`
  /// are `Repositories.activeSquishRefusals()`: items a squish already refused are listed under "Not squishable yet"
  /// with their reason instead of being offered again.
  /// `probedVideos` (`Repositories.passedVideoProbes`): a video starts selected only after its format passed the probe.
  /// `videoFacts` (`Repositories.videoProbeFacts`): what the probe measured. They count as probed too, and plan the
  /// video by its real size and codec; one the Store's estimate would offer but its facts don't is listed under "Not
  /// squishable yet" ("Already compact (HEVC)").
  public static func make(records: [AssetRecord], keep4K: Bool, excluding: Set<String>,
                          refusals: [SquishRefusalRecord] = [], probedVideos: Set<String> = [],
                          videoFacts: [String: VideoProbeFacts] = [:]) -> SquishCatalog {
    let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let remembered = refusals.filter { byId[$0.assetId].map { !$0.deleted } ?? false && !excluding.contains($0.assetId) }
    let refusedIds = Set(remembered.map(\.assetId))
    let items = SquishPlanner.plan(records: records, keep4K: keep4K, excluding: excluding.union(refusedIds),
                                   videoFacts: videoFacts)
      .sorted { ($0.estimatedBytes, $1.assetID) > ($1.estimatedBytes, $0.assetID) }
    let byFormat = records
      .filter { !$0.deleted && !excluding.contains($0.id) && !refusedIds.contains($0.id) }
      .filter { $0.mediaType == SquishCandidates.imageMediaType }
      .filter { $0.estBytes > SquishCandidates.minPhotoBytes && $0.subtypes & SquishCandidates.excludedSubtypes == 0 }
      .compactMap { r in SquishRefusal.formatReason(uti: r.uti).map { NotSquishable(assetID: r.id, estimatedBytes: r.estBytes, reason: $0) } }
    let offeredIds = Set(items.map(\.assetID))
    let compact = records
      .filter { !excluding.contains($0.id) && !refusedIds.contains($0.id) && !offeredIds.contains($0.id) }
      .compactMap { r -> NotSquishable? in
        guard let facts = videoFacts[r.id], SquishPlanner.offer(for: r, keep4K: keep4K) != nil else { return nil }
        return NotSquishable(assetID: r.id, estimatedBytes: SquishCandidates.sourceBytes(r, facts: facts),
                             reason: facts.isHEVC ? SquishRefusal.alreadyCompactHEVC : SquishRefusal.alreadyCompact)
      }
    let refused = (byFormat + compact + remembered.map {
      NotSquishable(assetID: $0.assetId, estimatedBytes: byId[$0.assetId]?.estBytes ?? 0, reason: $0.reason)
    }).sorted { ($0.estimatedBytes, $1.assetID) > ($1.estimatedBytes, $0.assetID) }
    let offered = offeredIds
    let probed = probedVideos.union(videoFacts.keys)
    return SquishCatalog(items: items, notSquishable: refused.filter { $0.reason != SquishRefusal.hdrVideoKept },
                         // The original-resource check, like the default selection (not `cloudOnly`, which is about
                         // the preview): not checked yet counts as iCloud.
                         cloudOnly: Set(records.filter { $0.locality != .onDevice && offered.contains($0.id) }.map(\.id)),
                         hdrKept: refused.filter { $0.reason == SquishRefusal.hdrVideoKept },
                         defaultSelection: items.filter { item in
                           byId[item.assetID]?.locality == .onDevice
                             && (item.kind == .photo || probed.contains(item.assetID))
                         }.map(\.assetID))
  }

  public static func load(repositories: Repositories, keep4K: Bool) async throws -> SquishCatalog {
    let records = try await repositories.liveAssetsSlim()
    // Copies Roll made, and originals whose squish isn't settled (their copy may still sit next to them).
    let excluding = try await repositories.journaledCopyIDs().union(try await repositories.openJournalAssetIDs())
    let facts = try await repositories.videoProbeFacts()
    return make(records: records, keep4K: keep4K, excluding: excluding,
                refusals: try await repositories.activeSquishRefusals(),
                probedVideos: Set(facts.keys), videoFacts: facts)
  }
}

/// The outcome of the Squish button (`SquishCatalog.start`).
public enum SquishStart: Sendable, Equatable {
  /// Queue these ids (most bytes first); `allowNetwork` lets iCloud originals download.
  case run(ids: [String], allowNetwork: Bool)
  /// Nothing can run now; the screen shows the notice.
  case blocked(SquishNotice)
  case nothing
}

/// An alert on the Squish screen: a specific title and one plain sentence or two.
public struct SquishNotice: Sendable, Equatable {
  public let title: String
  public let message: String

  public init(title: String, message: String) {
    self.title = title
    self.message = message
  }

  /// Every selected original is only in iCloud and there's no Wi-Fi (device QA: this was "Something went wrong").
  public static let needsWiFi = SquishNotice(
    title: "Wi-Fi needed", message: "Originals in iCloud download on Wi-Fi only. Connect to Wi-Fi and try again.")
  public static let couldntLoad = SquishNotice(
    title: "Squish couldn't load", message: "The list of items to squish couldn't be read. Try again in a moment.")
  public static let couldntQueue = SquishNotice(
    title: "Squish couldn't start", message: "The selection couldn't be saved. Nothing was changed.")
}

/// The Squish screen queues its selection under the hidden system swipefile `__squish__`, so applying it goes through
/// `CommitPlanner` and `PhotoKitCommitter` like every other change (quota, Store bookkeeping, one prompt).
public enum SquishQueue {
  public static let swipefileId = "__squish__"

  public static func swipefile(created: Double) -> SwipefileRecord {
    SwipefileRecord(id: swipefileId, name: "Squish", kind: .custom, prompts: [], action: .squish, created: created)
  }

  /// Makes the queue exactly `selection`, in that order (earlier ids are prepared first).
  public static func replace(with selection: [String], repositories: Repositories,
                             now: Double = Date().timeIntervalSince1970) async throws {
    if try await repositories.swipefile(id: swipefileId) == nil { try await repositories.save(swipefile(created: now)) }
    let wanted = Set(selection)
    for decision in try await repositories.queued(for: swipefileId) where !wanted.contains(decision.assetId) {
      try await repositories.undo(swipefileId: swipefileId, assetId: decision.assetId)
    }
    for (offset, id) in selection.enumerated() {
      try await repositories.record(DecisionRecord(swipefileId: swipefileId, assetId: id, verdict: .action,
                                                   decidedAt: now + Double(offset) / 1_000_000))
    }
  }
}
