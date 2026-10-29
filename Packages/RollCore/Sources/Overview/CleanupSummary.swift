import Dedupe
import Foundation
import Ranking
import Signals
import Squish
import Store

/// The cleanup categories on Home and in the taste scan (spec §1, §10).
public enum CleanupCategory: String, CaseIterable, Sendable, Identifiable {
  case duplicates, similarShots, screenshots, blurry, bigVideos

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .duplicates: "Duplicates"
    case .similarShots: "Similar shots"
    case .screenshots: "Screenshots"
    case .blurry: "Blurry"
    case .bigVideos: "Big videos"
    }
  }
}

/// How many assets and about how many bytes (estimates, see `SizeEstimator`).
public struct CategoryTotal: Sendable, Equatable {
  public var count: Int
  public var bytes: Int64
  /// The part of `bytes` whose originals are on this iPhone (`AssetRecord.locality == .onDevice`).
  public var onDeviceBytes: Int64
  /// The part of `bytes` whose originals are in iCloud or not checked yet (unknown counts as iCloud).
  public var inCloudBytes: Int64

  public static let zero = CategoryTotal(count: 0, bytes: 0)

  public init(count: Int, bytes: Int64, onDeviceBytes: Int64 = 0, inCloudBytes: Int64 = 0) {
    self.count = count; self.bytes = bytes; self.onDeviceBytes = onDeviceBytes; self.inCloudBytes = inCloudBytes
  }
}

/// One group from `DuplicateGrouper`, with its default keeper.
public struct DuplicateGroup: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// Every member's perceptual hash is within `DuplicateGrouper.nearPhashDistance` bits of the keeper's:
    /// exact or near-exact copies.
    case duplicates
    /// Linked by feature print or burst: the same moment shot more than once.
    case similarShots
  }

  /// The first member's id (stable while the group's membership is).
  public var id: String
  /// In creation order.
  public var members: [String]
  /// `KeeperPolicy`'s pick; the user can change it in the group view.
  public var keeper: String
  public var kind: Kind
  /// About how much deleting everyone but the keeper frees.
  public var reclaimableBytes: Int64

  public init(id: String, members: [String], keeper: String, kind: Kind, reclaimableBytes: Int64) {
    self.id = id; self.members = members; self.keeper = keeper; self.kind = kind
    self.reclaimableBytes = reclaimableBytes
  }

  /// Everyone but the keeper.
  public var others: [String] { members.filter { $0 != keeper } }
}

/// What Home shows: per-category counts and sizes, the duplicate groups, and the queue.
public struct CleanupSummary: Sendable, Equatable {
  public var totals: [CleanupCategory: CategoryTotal] = [:]
  /// Ordered like `DuplicateGrouper`'s output: most bytes first.
  public var groups: [DuplicateGroup] = []
  /// About how much Home's cleanups free, each asset counted once: deleting duplicates and similar shots (all but
  /// keepers), screenshots and blurry shots at their full size, plus squishing big videos at their estimated savings
  /// (`bigVideoSavings`), not their full size.
  public var freeableBytes: Int64 = 0
  /// About how much squishing the big videos saves (`SquishPlanner.offer`, 1080p cap), counting only the ones Squish
  /// would offer. A big video that is also a deletion candidate (a duplicate, say) counts at full size instead.
  public var bigVideoSavings: Int64 = 0
  /// The part of `freeableBytes` whose originals are on this iPhone: what deleting (and squishing) can free on the
  /// device. Home's headline uses this (capped by `onDeviceHeadline`), never `freeableBytes`.
  public var freeableOnDevice: Int64 = 0
  /// The part of `freeableBytes` whose originals are in iCloud, or not checked yet (unknown counts as iCloud): freeing
  /// it frees iCloud space, not the phone's, as far as Roll knows.
  public var freeableInCloud: Int64 = 0
  /// `bigVideoSavings` for videos on this iPhone.
  public var bigVideoSavingsOnDevice: Int64 = 0
  /// Every cleanup candidate (deletions, and big videos Squish would offer), largest first, whatever its locality: what
  /// `LocalityScanner` checks.
  public var localityCandidates: [String] = []
  /// Every live asset.
  public var library = CategoryTotal.zero
  /// Distinct live assets with a decision waiting to be applied in the user's swipefiles (`CleanupScanner` leaves the
  /// hidden system queues out: Duplicates, Similar shots and Squish show their own).
  public var queued = CategoryTotal.zero
  /// Swipefiles the user sees (presets and custom; not the hidden system ones).
  public var swipefileCount = 0

  public init() {}

  public subscript(category: CleanupCategory) -> CategoryTotal { totals[category] ?? .zero }

  public func groups(_ kind: DuplicateGroup.Kind) -> [DuplicateGroup] { groups.filter { $0.kind == kind } }

  /// Pure: builds the summary from live records and `DuplicateGrouper` groups (ids not in `records` are dropped,
  /// and a group left with fewer than 2 members is dropped). `squishExcluding` are ids Squish won't offer (copies Roll
  /// made, remembered refusals); they add no squish savings. `probedVideos` are the videos whose format passed Squish's
  /// probe (`Repositories.passedVideoProbes`): any other video adds no squish savings, on this iPhone or in iCloud (it
  /// may be Dolby Vision); it still counts in full when it's a deletion candidate. nil treats every video as probed
  /// (pure tests and previews only; `CleanupScanner` always passes the Store's set). `videoFacts`
  /// (`Repositories.videoProbeFacts`) plan probed videos by what their file measured, so an already compact one adds
  /// no squish savings.
  public static func make(records: [AssetRecord], groups rawGroups: [[String]], queuedAssetIds: [String] = [],
                          swipefileCount: Int = 0, squishExcluding: Set<String> = [],
                          probedVideos: Set<String>? = nil,
                          videoFacts: [String: VideoProbeFacts] = [:]) -> CleanupSummary {
    var summary = CleanupSummary()
    let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    summary.library = total(records)
    summary.swipefileCount = swipefileCount

    var freeable = Set<String>()
    var bigVideos: [AssetRecord] = []
    for (category, preset) in [(CleanupCategory.screenshots, Preset.screenshots), (.blurry, .blurry),
                               (.bigVideos, .bigVideos)] {
      let matching = records.filter(preset.candidateFilter)
      summary.totals[category] = total(matching)
      if category == .bigVideos { bigVideos = matching } else { freeable.formUnion(matching.map(\.id)) }
    }

    var others: [DuplicateGroup.Kind: [AssetRecord]] = [:]
    for raw in rawGroups {
      let members = raw.compactMap { byId[$0] }
      guard members.count >= 2 else { continue }
      let keeperId = KeeperPolicy.keeper(members)
      let keeper = members.first { $0.id == keeperId }!
      let rest = members.filter { $0.id != keeperId }
      let kind = kind(keeper: keeper, others: rest)
      summary.groups.append(DuplicateGroup(id: members[0].id, members: members.map(\.id), keeper: keeperId, kind: kind,
                                           reclaimableBytes: rest.reduce(0) { $0 + $1.estBytes }))
      others[kind, default: []] += rest
      freeable.formUnion(rest.map(\.id))
    }
    summary.totals[.duplicates] = total(others[.duplicates] ?? [])
    summary.totals[.similarShots] = total(others[.similarShots] ?? [])
    var candidates: [(id: String, bytes: Int64)] = []
    for video in bigVideos where !freeable.contains(video.id) && !squishExcluding.contains(video.id) {
      guard let savings = SquishPlanner.offer(for: video, keep4K: false, facts: videoFacts[video.id])?.estimatedSavings
      else { continue }
      candidates.append((video.id, video.estBytes))
      guard probedVideos.map({ $0.contains(video.id) }) != false else { continue }
      summary.bigVideoSavings += savings
      switch video.locality {
      case .onDevice: summary.bigVideoSavingsOnDevice += savings
      case .iCloud, .unknown: summary.freeableInCloud += savings
      }
    }
    for id in freeable {
      guard let record = byId[id] else { continue }
      summary.freeableBytes += record.estBytes
      candidates.append((record.id, record.estBytes))
      switch record.locality {
      case .onDevice: summary.freeableOnDevice += record.estBytes
      case .iCloud, .unknown: summary.freeableInCloud += record.estBytes
      }
    }
    summary.freeableBytes += summary.bigVideoSavings
    summary.freeableOnDevice += summary.bigVideoSavingsOnDevice
    summary.localityCandidates = candidates.sorted { ($0.bytes, $1.id) > ($1.bytes, $0.id) }.map(\.id)
    summary.queued = total(Set(queuedAssetIds).compactMap { byId[$0] })
    return summary
  }

  static func kind(keeper: AssetRecord, others: [AssetRecord]) -> DuplicateGroup.Kind {
    guard let hash = keeper.phash else { return .similarShots }
    let near = others.allSatisfy { other in
      other.phash.map { (hash ^ $0).nonzeroBitCount <= DuplicateGrouper.nearPhashDistance } ?? false
    }
    return near ? .duplicates : .similarShots
  }

  private static func total(_ records: [AssetRecord]) -> CategoryTotal {
    CategoryTotal(count: records.count, bytes: records.reduce(0) { $0 + $1.estBytes },
                  onDeviceBytes: records.reduce(0) { $0 + ($1.locality == .onDevice ? $1.estBytes : 0) },
                  inCloudBytes: records.reduce(0) { $0 + ($1.locality == .onDevice ? 0 : $1.estBytes) })
  }

  /// Home's headline: `freeableOnDevice`, never more than the space the device has in use
  /// (`total - volumeAvailableCapacityForImportantUsage`) when that's known.
  public func onDeviceHeadline(deviceTotal: Int64?, deviceAvailable: Int64?) -> Int64 {
    Self.capped(freeableOnDevice, deviceTotal: deviceTotal, deviceAvailable: deviceAvailable)
  }

  /// `bytes`, capped at the space in use on the device (`total - available`, at least 0) when both are known.
  public static func capped(_ bytes: Int64, deviceTotal: Int64?, deviceAvailable: Int64?) -> Int64 {
    guard let deviceTotal, let deviceAvailable else { return bytes }
    return min(bytes, max(0, deviceTotal - deviceAvailable))
  }
}

/// Reads the Store and builds a `CleanupSummary`, in two parts with different costs:
/// - `groups()` reads every live row with its feature print (about 3 KB each) and runs `DuplicateGrouper` (each print
///   decoded at most once). Run it when indexing finishes, or now and then while it runs.
/// - `scan(groups:)` reads the slim rows (`liveAssetsSlim`, no prints) and does the totals, reusing earlier groups.
///   Ids that left the library since the groups were made are dropped.
public struct CleanupScanner: Sendable {
  private let repositories: Repositories

  public init(repositories: Repositories) { self.repositories = repositories }

  /// Both parts: fresh groups, then the totals.
  public func scan() async throws -> CleanupSummary {
    try await scan(groups: try await groups())
  }

  /// Duplicate groups over the live library (ids, in `DuplicateGrouper` order).
  public func groups() async throws -> [[String]] {
    // Only rows analysed from images big enough to compare (`AssetRecord.groupable`).
    let records = try await repositories.liveAssets().filter(\.groupable)
    // A squished copy looks like a duplicate of its original: copies Roll made are never grouped.
    let copies = try await repositories.journaledCopyIDs()
    return DuplicateGrouper.groups(records: records, excluding: copies, prepare: FeaturePrints.decode,
                                   distance: { $0.distance(to: $1) })
  }

  /// The totals over the slim rows, with `groups` from an earlier `groups()`.
  public func scan(groups: [[String]]) async throws -> CleanupSummary {
    let records = try await repositories.liveAssetsSlim()
    let facts = try await repositories.videoProbeFacts()
    let copies = try await repositories.journaledCopyIDs()
    let swipefiles = try await repositories.swipefiles()
    var queued: [String] = []
    for swipefile in swipefiles where !SystemSwipefile.isHidden(swipefile) {
      queued += try await repositories.queued(for: swipefile.id).map(\.assetId)
    }
    return .make(records: records, groups: groups, queuedAssetIds: queued,
                 swipefileCount: swipefiles.filter { !SystemSwipefile.isHidden($0) }.count,
                 squishExcluding: copies.union(try await repositories.activeSquishRefusals().map(\.assetId))
                   .union(try await repositories.openJournalAssetIDs()),
                 probedVideos: Set(facts.keys), videoFacts: facts)
  }
}

/// Swipefiles the app keeps for itself (ids starting with `__`), hidden from the swipefile list.
public enum SystemSwipefile {
  /// Decisions queued from the Duplicates screen (spec §6).
  public static let duplicatesId = "__duplicates__"
  /// Decisions queued from the Similar shots screen.
  public static let similarShotsId = "__similar__"

  public static func isHidden(_ swipefile: SwipefileRecord) -> Bool { swipefile.id.hasPrefix("__") }
}
