import Foundation
import Store
import Synchronization
import Testing
@testable import Commit
import Entitlements
@testable import Squish
import SquishBridge

private enum RunnerSample {
  static let photo: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("runner-sample-\(UUID().uuidString).jpg")
    try! Fixtures.makeJPEG(at: url, width: 1600, height: 1200)
    return url
  }()
}

/// ReplaceFlow over the fake library, behind the SquishRunner seam.
private struct RunnerRig {
  let library: FakeLibrary
  let database: AppDatabase
  let repositories: Repositories
  let registry = PreparedRegistry()
  let root: URL

  init(ids: [String] = ["a", "b"]) throws {
    root = try Fixtures.tempDir()
    library = FakeLibrary(source: RunnerSample.photo)
    for id in ids { library.addPhoto(id) }
    database = try AppDatabase.inMemory()
    repositories = Repositories(database)
  }

  func runner(keep4K: Bool = false, registry: PreparedRegistry? = nil) -> ReplaceFlowRunner {
    let flow = ReplaceFlow(gateway: library, journal: repositories, workspace: SquishWorkspace(root: root),
                           space: SquishDiskSpace(available: { 100_000_000_000 }), background: NoBackgroundExecution(),
                           allowNetwork: false)
    return ReplaceFlowRunner(flow: flow, keep4K: keep4K, registry: registry ?? self.registry)
  }

  func requests(_ ids: [String]) -> [SquishRequest] { ids.map { SquishRequest(assetID: $0, estimatedBytes: 5_000_000) } }
  func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class StageLog: Sendable {
  private let items = Mutex<[SquishStage]>([])
  func add(_ stage: SquishStage) { items.withLock { $0.append(stage) } }
  var stages: [SquishStage] { items.withLock { $0 } }
}

/// Plain deletes and album moves aren't part of these tests.
private struct NoOpCommitLibrary: CommitLibrary {
  func delete(_ ids: [String]) async throws {}
  func addToAlbum(named name: String, _ ids: [String]) async throws {}
}

private struct NotPro: ProStatus {
  var isPro: Bool { false }
}

@Suite(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
struct ReplaceFlowRunnerTests {
  @Test func preparesThenDeletesOriginalsThroughTheSeam() async throws {
    let rig = try RunnerRig()
    defer { rig.cleanUp() }
    let runner = rig.runner()
    let log = StageLog()
    let batch = await runner.prepare(rig.requests(["a", "b"])) { log.add($0.stage) }
    #expect(batch.failures.isEmpty && !batch.cancelled)
    #expect(batch.prepared.map(\.assetID) == ["a", "b"])
    #expect(batch.prepared.allSatisfy { $0.newBytes > 0 && $0.newBytes < $0.originalBytes })
    #expect(Set(log.stages) == [.downloading, .encoding, .saving, .verifying])
    #expect(rig.library.has("a") && rig.library.has("b"))

    let deletion = try await runner.commitDeletes(batch.prepared)
    #expect(deletion.deleted.map(\.assetID) == ["a", "b"])
    #expect(deletion.skipped.isEmpty)
    #expect(!rig.library.has("a") && !rig.library.has("b"))
    #expect(batch.prepared.allSatisfy { rig.library.has($0.newAssetID) })
  }

  @Test func limitedAccessMapsToNeedsFullAccess() async throws {
    let rig = try RunnerRig()
    defer { rig.cleanUp() }
    rig.library.configure { $0.access = .limited }
    let batch = await rig.runner().prepare(rig.requests(["a"]), progress: nil)
    #expect(batch.prepared.isEmpty)
    let failure = try #require(batch.failures.first)
    #expect(failure.error as? SquishRunnerError == .needsFullAccess)
    #expect(SquishRefusal.classify(failure.error) == .needsFullAccess)
    await #expect(throws: SquishRunnerError.needsFullAccess) { _ = try await rig.runner().reconcile() }
  }

  @Test func aDeclinedPromptMapsToUserDeclinedDeleteAndKeepsEverything() async throws {
    let rig = try RunnerRig()
    defer { rig.cleanUp() }
    let runner = rig.runner()
    let batch = await runner.prepare(rig.requests(["a"]), progress: nil)
    rig.library.configure { $0.declineDelete = true }
    await #expect(throws: SquishRunnerError.userDeclinedDelete) { _ = try await runner.commitDeletes(batch.prepared) }
    #expect(rig.library.has("a") && rig.library.has(batch.prepared[0].newAssetID))
    // A retry after the user changes their mind goes through.
    rig.library.configure { $0.declineDelete = false }
    #expect(try await runner.commitDeletes(batch.prepared).deleted.map(\.assetID) == ["a"])
  }

  @Test func unknownCopiesAreSkippedNotDeleted() async throws {
    let rig = try RunnerRig()
    defer { rig.cleanUp() }
    let stranger = SquishedCopy(assetID: "a", newAssetID: "new-unknown", originalBytes: 10, newBytes: 5)
    let deletion = try await rig.runner().commitDeletes([stranger])
    #expect(deletion.deleted.isEmpty && deletion.skipped.isEmpty && deletion.unregistered == [stranger])
    #expect(rig.library.has("a"))
  }

  @Test func formatRefusalsAreClassifiedAsNotSquishable() async throws {
    let rig = try RunnerRig(ids: [])
    defer { rig.cleanUp() }
    rig.library.addPhoto("heic", uti: "public.heic")
    let batch = await rig.runner().prepare(rig.requests(["heic"]), progress: nil)
    let failure = try #require(batch.failures.first)
    #expect(SquishRefusal.classify(failure.error) == .notSquishable(SquishRefusal.text(for: .unsupportedFormat)))
  }

  @Test func reconcileRegistersPendingPairsForAnotherRunner() async throws {
    let rig = try RunnerRig()
    defer { rig.cleanUp() }
    let batch = await rig.runner(registry: PreparedRegistry()).prepare(rig.requests(["a"]), progress: nil)
    // A relaunch: a fresh registry knows nothing until reconcile.
    let relaunched = rig.runner(registry: PreparedRegistry())
    let recovery = try await relaunched.reconcile()
    #expect(recovery.pending == batch.prepared)
    #expect(recovery.orphanCopyIDs.isEmpty)
    #expect(try await relaunched.commitDeletes(recovery.pending).deleted.map(\.assetID) == ["a"])
    #expect(try await rig.repositories.journaledCopyIDs().contains(batch.prepared[0].newAssetID))
  }

  @Test func keep4KReachesTheSquishItem() async throws {
    let rig = try RunnerRig()
    defer { rig.cleanUp() }
    #expect(rig.runner(keep4K: true).keep4K)
    let batch = await rig.runner(keep4K: true).prepare(rig.requests(["a"]), progress: nil)
    #expect(batch.prepared.count == 1)
  }

  /// The whole path: queue → plan → committer → runner → Store bookkeeping and quota.
  @Test func committerAppliesASquishQueueAndSpendsQuota() async throws {
    let rig = try RunnerRig()
    defer { rig.cleanUp() }
    try await rig.repositories.upsertAssets(["a", "b"].map {
      AssetRecord(id: $0, mediaType: 1, subtypes: 0, uti: "public.jpeg", estBytes: 5_000_000)
    })
    try await SquishQueue.replace(with: ["b", "a"], repositories: rig.repositories, now: 1)
    let queued = try await rig.repositories.queued(for: SquishQueue.swipefileId)
    #expect(queued.map(\.assetId) == ["b", "a"])
    let records = Dictionary(uniqueKeysWithValues: try await rig.repositories.assets(ids: ["a", "b"]).map { ($0.id, $0) })
    let swipefile = try #require(try await rig.repositories.swipefile(id: SquishQueue.swipefileId))
    let plan = CommitPlanner.plan(queued: queued, records: records, swipefiles: [swipefile.id: swipefile], isPro: false,
                                  quotaRemaining: 50)
    #expect(plan.squishes.map(\.assetID) == ["b", "a"])

    let committer = PhotoKitCommitter(library: NoOpCommitLibrary(), database: rig.database, pro: NotPro(),
                                      squish: rig.runner())
    guard case .applied(let report) = try await committer.apply(plan) else {
      Issue.record("expected .applied")
      return
    }
    #expect(Set(report.squished.map(\.assetID)) == ["a", "b"])
    #expect(report.estimatedSquishSavings > 0)
    #expect(report.quotaSpent == 2)
    #expect(try await rig.repositories.queued(for: SquishQueue.swipefileId).isEmpty)
    #expect(try await rig.repositories.asset(id: "a")?.deleted == true)
  }
}

struct SquishQueueAndCatalogTests {
  @Test func replacingTheQueueDropsWhatIsNoLongerSelected() async throws {
    let repositories = Repositories(try AppDatabase.inMemory())
    try await SquishQueue.replace(with: ["a", "b"], repositories: repositories, now: 1)
    try await SquishQueue.replace(with: ["c", "a"], repositories: repositories, now: 2)
    #expect(try await repositories.queued(for: SquishQueue.swipefileId).map(\.assetId) == ["c", "a"])
    #expect(try await repositories.swipefile(id: SquishQueue.swipefileId)?.action == .squish)
  }

  @Test func catalogOffersCandidatesAndListsFormatRefusals() {
    let records = [
      AssetRecord(id: "jpeg", mediaType: 1, subtypes: 0, uti: "public.jpeg", estBytes: 6_000_000, originalLocal: true),
      AssetRecord(id: "heic", mediaType: 1, subtypes: 0, uti: "public.heic", estBytes: 7_000_000),
      AssetRecord(id: "raw", mediaType: 1, subtypes: 0, uti: "com.adobe.raw-image", estBytes: 30_000_000),
      AssetRecord(id: "smallHeic", mediaType: 1, subtypes: 0, uti: "public.heic", estBytes: 1_000_000),
      AssetRecord(id: "live", mediaType: 1, subtypes: SquishCandidates.photoLive, uti: "public.heic", estBytes: 9_000_000),
      AssetRecord(id: "copy", mediaType: 1, subtypes: 0, uti: "public.jpeg", estBytes: 8_000_000),
      AssetRecord(id: "cloud", mediaType: 1, subtypes: 0, uti: "public.png", estBytes: 4_000_000, cloudOnly: true,
                  originalLocal: false),
    ]
    let catalog = SquishCatalog.make(records: records, keep4K: false, excluding: ["copy"])
    #expect(catalog.items.map(\.assetID) == ["jpeg", "cloud"])
    #expect(catalog.notSquishable.map(\.assetID) == ["raw", "heic"])
    #expect(catalog.notSquishable.last?.reason == "Already compressed (HEIC)")
    #expect(catalog.cloudOnly == ["cloud"])
  }

  @Test func originalsWithAnOpenSquishAreNotOfferedAgain() async throws {
    let repositories = Repositories(try AppDatabase.inMemory())
    let video = { (id: String) in
      AssetRecord(id: id, mediaType: 2, subtypes: 0, pixelW: 1920, pixelH: 1080, duration: 60, estBytes: 75_000_000)
    }
    try await repositories.upsertAssets([video("declined"), video("other"), video("copy")])
    // A declined prompt leaves a verified copy next to its original.
    try await repositories.journalBegin(assetID: "declined", originalBytes: 75_000_000, newBytes: 30_000_000)
    try await repositories.journalNoteNewAssetAsync(assetID: "declined", newAssetID: "copy")
    try await repositories.journalSetState(assetID: "declined", state: .verified, payload: nil)
    #expect(try await SquishCatalog.load(repositories: repositories, keep4K: false).items.map(\.assetID) == ["other"])

    try await repositories.journalSetState(assetID: "declined", state: .discarded, payload: nil)
    #expect(try await SquishCatalog.load(repositories: repositories, keep4K: false).items.map(\.assetID)
      == ["copy", "declined", "other"], "once the copy is discarded the original (and the deleted copy's row) settle")
  }

  @Test func aSecondBeginWhileACopyIsOpenReadsAsAWaitingCopy() {
    #expect(SquishRefusal.classify(ReplaceError.createFailed(SquishJournalError.openEntry(assetID: "a", state: .verified)))
      == .failed("A copy from an earlier squish is still waiting. Finish or remove it on Home first."))
  }

  @Test func rememberedRefusalsAreListedNotOfferedUntilTheAssetChanges() async throws {
    let repositories = Repositories(try AppDatabase.inMemory())
    let dolby = AssetRecord(id: "dolby", mediaType: 2, subtypes: 0, pixelW: 1920, pixelH: 1080, duration: 60,
                            estBytes: 75_000_000, modified: 100)
    let other = AssetRecord(id: "other", mediaType: 2, subtypes: 0, pixelW: 1920, pixelH: 1080, duration: 60,
                            estBytes: 70_000_000, modified: 100)
    try await repositories.upsertAssets([dolby, other])
    #expect(try await SquishCatalog.load(repositories: repositories, keep4K: false).items.map(\.assetID)
      == ["dolby", "other"])

    try await repositories.recordSquishRefusal(assetId: "dolby", reason: "Dolby Vision")
    try await repositories.recordSquishRefusal(assetId: "unknown", reason: "ignored")
    let refused = try await SquishCatalog.load(repositories: repositories, keep4K: false)
    #expect(refused.items.map(\.assetID) == ["other"])
    #expect(refused.notSquishable == [NotSquishable(assetID: "dolby", estimatedBytes: 75_000_000, reason: "Dolby Vision")])

    // Edited (or favorited...) in Photos: the library reports a new modification date, so it's offered again.
    var edited = dolby
    edited.modified = 200
    try await repositories.upsertAssets([edited])
    let again = try await SquishCatalog.load(repositories: repositories, keep4K: false)
    #expect(again.items.map(\.assetID) == ["dolby", "other"])
    #expect(again.notSquishable.isEmpty)
  }

  @Test func refusalTextCoversEveryReasonAndKeepsTheLimitations() {
    #expect(SquishRefusal.classify(ReplaceError.ineligible(.livePhoto)) == .notSquishable("Live Photo"))
    #expect(SquishRefusal.classify(ReplaceError.needsDownload) == .needsDownload)
    #expect(SquishRefusal.classify(SquishRunnerError.needsFullAccess) == .needsFullAccess)
    #expect(SquishLimitations.items.contains(
      "If you use iCloud Shared Library, squished items are moved to your Personal Library and removed for other participants."))
  }
}
