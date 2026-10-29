import Foundation
import Store
import Synchronization
import Testing
@testable import Squish

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [SquishProgress] = []
  func add(_ p: SquishProgress) { lock.withLock { items.append(p) } }
  var phases: [SquishPhase] { lock.withLock { items.map(\.phase) } }
}

final class FakeBackground: BackgroundExecution, @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: [@Sendable () -> Void] = []
  private(set) var began = 0, ended = 0
  func begin(name: String, onExpiration: @escaping @Sendable () -> Void) -> Int? {
    lock.withLock { began += 1; handlers.append(onExpiration); return began }
  }
  func end(_ token: Int) { lock.withLock { ended += 1 } }
  func expire() { let hs = lock.withLock { handlers }; hs.forEach { $0() } }
}

private enum Sample {
  /// One small noisy JPEG shared by the tests; copied into each fake export.
  static let photo: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("squish-sample-\(UUID().uuidString).jpg")
    try! Fixtures.makeJPEG(at: url, width: 1600, height: 1200)
    return url
  }()
}

private struct Rig {
  let flow: ReplaceFlow
  let library: FakeLibrary
  let background: FakeBackground
  let journal: Repositories
  let root: URL

  init(source: URL = Sample.photo, width: Int = 1600, height: Int = 1200, space: @escaping @Sendable () -> Int64 = { 100_000_000_000 },
       ids: [String] = ["a", "b"]) throws {
    root = try Fixtures.tempDir()
    library = FakeLibrary(source: source, width: width, height: height)
    for id in ids { library.addPhoto(id) }
    background = FakeBackground()
    journal = Repositories(try AppDatabase.inMemory())
    flow = ReplaceFlow(gateway: library, journal: journal, workspace: SquishWorkspace(root: root),
                       space: SquishDiskSpace(available: space), background: background, allowNetwork: true)
  }

  func item(_ id: String, bytes: Int64 = 5_000_000) -> SquishItem { SquishItem(assetID: id, estimatedBytes: bytes) }
  var leftovers: [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] }
  func cleanUp() { try? FileManager.default.removeItem(at: root) }
  func state(_ id: String) async throws -> SquishJournalRecord.State? { try await journal.journalEntry(assetID: id)?.state }
}

@Suite(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
struct ReplaceFlowTests {
  // MARK: Happy path and journal

  @Test func prepareCreatesAndVerifiesWithoutTouchingOriginals() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let log = ProgressLog()
    let report = await rig.flow.prepare([rig.item("a")], progress: { log.add($0) })
    let p = try #require(report.prepared.first)
    #expect(report.failures.isEmpty && !report.cancelled)
    #expect(p.assetID == "a" && p.newAssetID == "new-1")
    #expect(p.newBytes > 0 && p.newBytes < p.originalBytes)
    #expect(p.estimatedSavings == p.originalBytes - p.newBytes)
    #expect(p.verifiedOriginal.albumIDs == ["A1"] && p.verifiedCopy.albumIDs == ["A1"])
    #expect(rig.library.has("a"), "the original is untouched")
    #expect(!rig.library.calls.contains { $0.hasPrefix("delete") })
    #expect(log.phases.filter { $0 != .downloading } == [.encoding, .saving, .verifying])
    #expect(rig.leftovers.isEmpty, "scratch files must be cleaned up")
    #expect(try await rig.state("a") == .verified)
    #expect(try await rig.journal.journaledCopyIDs() == ["new-1"])
    #expect(report.transferLimitations == SquishLimitations.items)
  }

  @Test func theJournalHasTheCopyIdBeforeTheCopyExists() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let seen = Mutex<(state: SquishJournalRecord.State?, id: String?, copyExists: Bool)>((nil, nil, true))
    let journal = rig.journal, library = rig.library
    rig.library.configure { $0.atPlaceholder = { id in
      let row = try? journal.journalEntrySync(assetID: "a")
      seen.withLock { $0 = (row?.state, row?.newAssetID, library.has(id)) }
    } }
    _ = await rig.flow.prepare([rig.item("a")])
    let s = seen.withLock { $0 }
    #expect(s.state == .creating, "begun before the change block runs")
    #expect(s.copyExists == false)
    // ...and the id is written (synchronously) once the placeholder is read.
    #expect(try await rig.journal.journalEntry(assetID: "a")?.newAssetID == "new-1")
  }

  @Test func batchDeletesAllOriginalsInOneRequestAfterEveryCopyExists() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let report = await rig.flow.prepare([rig.item("a"), rig.item("b")])
    #expect(report.prepared.count == 2)
    let result = try await rig.flow.commitDeletes(report.prepared)
    let calls = rig.library.calls
    #expect(calls.filter { $0.hasPrefix("delete:") } == ["delete:a,b"], "one change request for all originals")
    let lastCreate = try #require(calls.lastIndex { $0.hasPrefix("create") })
    let firstDelete = try #require(calls.firstIndex { $0.hasPrefix("delete") })
    #expect(lastCreate < firstDelete)
    #expect(result.deleted.count == 2 && result.skipped.isEmpty)
    #expect(result.recentlyDeletedPending)
    #expect(result.estimatedSavings == report.prepared.reduce(0) { $0 + $1.estimatedSavings })
    #expect(!rig.library.has("a") && !rig.library.has("b"))
    #expect(try await rig.state("a") == .committed)
  }

  @Test func duplicateIdsAreProcessedOnce() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let report = await rig.flow.prepare([rig.item("a"), rig.item("a"), rig.item("b"), rig.item("a")])
    #expect(report.prepared.map(\.assetID) == ["a", "b"])
    #expect(rig.library.calls.filter { $0 == "create:a" }.count == 1)
    let result = try await rig.flow.commitDeletes(report.prepared + report.prepared)
    #expect(result.deleted.count == 2)
    #expect(rig.library.calls.filter { $0.hasPrefix("delete:") } == ["delete:a,b"])
  }

  // MARK: C1 limited access

  @Test func limitedAccessRefusesEverythingBeforeTouchingTheLibrary() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.access = .limited }
    let report = await rig.flow.prepare([rig.item("a"), rig.item("b")])
    #expect(report.prepared.isEmpty)
    #expect(report.failures.map(\.error) == [.needsFullAccess, .needsFullAccess])
    #expect(rig.library.calls.isEmpty)
    await #expect(throws: ReplaceError.needsFullAccess) { try await rig.flow.commitDeletes([]) }
    await #expect(throws: ReplaceError.needsFullAccess) { try await rig.flow.discardCopy(newAssetId: "x") }
    await #expect(throws: ReplaceError.needsFullAccess) { try await rig.flow.reconcile() }
    #expect(rig.library.calls.isEmpty)
  }

  @Test func accessRevokedBetweenPrepareAndCommitStopsTheDelete() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let report = await rig.flow.prepare([rig.item("a")])
    rig.library.configure { $0.access = .limited }  // user narrows access in Settings
    await #expect(throws: ReplaceError.needsFullAccess) { try await rig.flow.commitDeletes(report.prepared) }
    #expect(rig.library.has("a") && rig.library.has("new-1"))
  }

  @Test func deniedAccessIsTreatedLikeLimited() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.access = .denied }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .needsFullAccess)
  }

  // MARK: Refusals

  @Test func ineligibleAssetsAreRefusedBeforeAnyWork() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.assets["a"]?.facts.resources = [.photo, .alternatePhoto] }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures == [PrepareFailure(assetID: "a", error: .ineligible(.multiResource))])
    #expect(rig.library.calls == ["inspect:a"])
    #expect(try await rig.state("a") == nil, "nothing journaled for a refused asset")
  }

  @Test func formatsOtherThanJPEGAndPNGAreRefused() async throws {
    let rig = try Rig(ids: []); defer { rig.cleanUp() }
    for (id, uti) in [("heic", "public.heic"), ("dng", "com.adobe.raw-image"), ("tiff", "public.tiff")] {
      rig.library.addPhoto(id, uti: uti)
    }
    let report = await rig.flow.prepare(["heic", "dng", "tiff"].map { rig.item($0) })
    #expect(report.failures.map(\.error) == Array(repeating: .ineligible(.unsupportedFormat), count: 3))
    #expect(!rig.library.calls.contains { $0.hasPrefix("export") })
  }

  // MARK: Space

  @Test func notEnoughFreeSpaceStopsBeforeExporting() async throws {
    let rig = try Rig(space: { 1_000_000_000 }); defer { rig.cleanUp() }
    let report = await rig.flow.prepare([rig.item("a", bytes: 400_000_000)])
    #expect(report.failures.first?.error == .insufficientSpace(required: 1_300_000_000, available: 1_000_000_000))
    #expect(!rig.library.calls.contains { $0.hasPrefix("export") })
  }

  @Test func spaceIsCheckedAgainWithTheRealExportedSize() async throws {
    // Plenty of room for the (tiny) estimate, but only 400 MB after the export: the 500 MB margin isn't there.
    let calls = Mutex(0)
    let rig = try Rig(space: { calls.withLock { n in n += 1; return n == 1 ? 10_000_000_000 : 400_000_000 } })
    defer { rig.cleanUp() }
    let report = await rig.flow.prepare([rig.item("a", bytes: 1_000)])
    guard case .insufficientSpace? = report.failures.first?.error else { Issue.record("expected insufficientSpace, got \(report.failures)"); return }
    #expect(rig.library.calls.contains("export:a"))
    #expect(!rig.library.calls.contains { $0.hasPrefix("create") })
    #expect(rig.leftovers.isEmpty)
  }

  // MARK: Source and copy verification

  @Test func cloudOnlyOriginalReportsNeedsDownload() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.export = .needsDownload }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .needsDownload)
    #expect(rig.leftovers.isEmpty)
  }

  @Test func aThumbnailSizedDownloadIsRefusedAsSource() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.export = .thumbnail }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .squish(.verificationFailed(SourceCheck.mismatchMessage)))
    #expect(!rig.library.calls.contains { $0.hasPrefix("create") })
  }

  @Test func mismatchedCopyIsReportedWithItsIdAndNothingIsDeleted() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.tamperCopy = { $0.fp.isFavorite = false } }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .verificationFailed(reason: "favorite state differs", newAssetId: "new-1"))
    #expect(report.leftoverCopyIDs == ["new-1"])
    #expect(report.prepared.isEmpty)
    #expect(try await rig.state("a") == .created, "still open in the journal until the copy is discarded")
    try await rig.flow.discardCopy(newAssetId: "new-1")
    #expect(rig.library.calls.last == "discard:new-1" && !rig.library.has("new-1"))
    #expect(try await rig.state("a") == .discarded)
    #expect(try await rig.journal.journaledCopyIDs().isEmpty)
  }

  @Test func photoCopyWithDifferentDimensionsIsRejected() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.tamperCopy = { $0.fp.pixelWidth -= 1 } }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .verificationFailed(reason: "dimensions differ", newAssetId: "new-1"))
  }

  @Test func aCopyWhoseStoredBytesDifferFromTheEncodedFileIsRejected() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.corruptReadBackHash = true }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .verificationFailed(reason: "copy content differs from the encoded file", newAssetId: "new-1"))
  }

  @Test func aCopyWithTheWrongResourceIsRejected() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.tamperCopy = { $0.stored?.resources = [.photo, .pairedVideo] } }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .verificationFailed(reason: "copy does not have exactly one resource", newAssetId: "new-1"))
  }

  // MARK: Create failures

  @Test func aFailedCreateLeavesNothingBehindAndClosesTheJournal() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.createError = CocoaError(.fileWriteOutOfSpace) }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .createFailed(CocoaError(.fileWriteOutOfSpace)))
    #expect(rig.library.copyIDs().isEmpty)
    #expect(try await rig.state("a") == .discarded)
    #expect(rig.leftovers.isEmpty)
  }

  @Test func anOriginalThatVanishesInsideTheChangeBlockCreatesNothing() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.originalVanishesDuringCreate = true }  // also covers "no placeholder": no copy is made
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .createFailed(ReplaceError.assetNotFound))
    #expect(rig.library.copyIDs().isEmpty)
    #expect(try await rig.state("a") == .discarded)
  }

  @Test func anOriginalThatVanishesAfterTheCopyIsMadeKeepsTheCopyOutOfCleanup() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.originalVanishesAfterCreate = true }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.failures.first?.error == .verificationFailed(reason: "original not found", newAssetId: nil))
    #expect(report.leftoverCopyIDs.isEmpty, "the copy is now the only version")
    let rec = try await rig.flow.reconcile()
    #expect(rec.pending.isEmpty && rec.orphans.isEmpty)
    #expect(try await rig.state("a") == .committed)
  }

  @Test func albumsTheCopyCannotJoinDoNotBlockIt() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.assets["a"]?.readOnlyAlbumIDs = ["shared-album"] }
    let report = await rig.flow.prepare([rig.item("a")])
    #expect(report.prepared.count == 1)
    #expect(rig.library.asset("new-1")?.readOnlyAlbumIDs.isEmpty == true)
  }

  // MARK: C2 commit re-verification

  private func prepared(_ rig: Rig, _ ids: [String] = ["a", "b"]) async -> [Prepared] {
    await rig.flow.prepare(ids.map { rig.item($0) }).prepared
  }

  @Test func anOriginalEditedAfterPrepareIsNotDeleted() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let batch = await prepared(rig)
    rig.library.edit("a")
    let result = try await rig.flow.commitDeletes(batch)
    #expect(result.deleted.map(\.assetID) == ["b"])
    #expect(result.skipped.map(\.prepared.assetID) == ["a"])
    #expect(result.skipped.first?.reason == .originalModified, "the modification date moved")
    #expect(rig.library.has("a") && !rig.library.has("b"))
    #expect(result.estimatedSavings == batch[1].estimatedSavings, "savings come only from what was deleted")
  }

  @Test func anEditWithoutADateChangeIsStillCaughtByTheEligibilityRecheck() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let batch = await prepared(rig, ["a"])
    rig.library.configure { $0.assets["a"]?.facts.resources.append(.edit) }
    let result = try await rig.flow.commitDeletes(batch)
    #expect(result.skipped.first?.reason == .ineligible(.edited))
    #expect(rig.library.has("a"))
  }

  @Test func anOriginalAddedToAnAlbumAfterPrepareIsNotDeleted() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let batch = await prepared(rig, ["a"])
    rig.library.addToAlbum("a", "A2")
    let result = try await rig.flow.commitDeletes(batch)
    #expect(result.skipped.first?.reason == .mismatch("album membership differs"))
    #expect(result.deleted.isEmpty && !result.recentlyDeletedPending)
    #expect(rig.library.has("a"))
    #expect(!rig.library.calls.contains { $0.hasPrefix("delete:") && $0 != "delete:" })
  }

  @Test func anOriginalFavoritedAfterPrepareIsNotDeleted() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.assets["a"]?.fp.isFavorite = false }
    let batch = await prepared(rig, ["a"])
    rig.library.setFavorite("a", true)
    let result = try await rig.flow.commitDeletes(batch)
    #expect(result.skipped.first?.reason == .mismatch("favorite state differs"))
    #expect(rig.library.has("a"))
  }

  @Test func aVanishedCopyKeepsItsOriginal() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let batch = await prepared(rig)
    rig.library.remove("new-1")
    let result = try await rig.flow.commitDeletes(batch)
    #expect(result.skipped.map(\.reason) == [.copyMissing])
    #expect(result.deleted.map(\.assetID) == ["b"])
    #expect(rig.library.has("a"))
  }

  @Test func secondCommitOfTheSameBatchChangesNothing() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let batch = await prepared(rig)
    let first = try await rig.flow.commitDeletes(batch)
    let second = try await rig.flow.commitDeletes(batch)
    #expect(first.deleted.count == 2)
    #expect(second.deleted.isEmpty && second.estimatedSavings == 0 && !second.recentlyDeletedPending)
    #expect(second.skipped.map(\.reason) == [.originalMissing, .originalMissing])
    #expect(rig.library.has("new-1") && rig.library.has("new-2"), "copies are never touched")
  }

  @Test func decliningTheDeleteKeepsEverythingAndRetryWorks() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let batch = await prepared(rig, ["a"])
    rig.library.configure { $0.declineDelete = true }
    await #expect(throws: ReplaceError.userDeclinedDelete) { try await rig.flow.commitDeletes(batch) }
    #expect(rig.library.has("a") && rig.library.has("new-1"))
    #expect(try await rig.state("a") == .verified)
    rig.library.configure { $0.declineDelete = false }
    let result = try await rig.flow.retryDelete(batch)
    #expect(result.deleted == batch)
  }

  @Test func aNonCancelDeleteFailureKeepsEverythingAndSaysSo() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let batch = await prepared(rig, ["a"])
    rig.library.configure { $0.deleteError = CocoaError(.fileWriteNoPermission) }
    await #expect(throws: ReplaceError.deleteFailed(CocoaError(.fileWriteNoPermission))) { try await rig.flow.commitDeletes(batch) }
    #expect(rig.library.has("a") && rig.library.has("new-1"))
    #expect(try await rig.state("a") == .verified)
  }

  // MARK: Journal reconciliation

  @Test func reconcileSettlesEveryOpenRow() async throws {
    let rig = try Rig(ids: ["a", "b", "c", "d", "e", "f"]); defer { rig.cleanUp() }
    // a: crashed before the library returned an id -> never created
    try await rig.journal.journalBegin(assetID: "a", originalBytes: 1, newBytes: 1)
    // b: id recorded but the change never committed -> no copy
    try await rig.journal.journalBegin(assetID: "b", originalBytes: 1, newBytes: 1)
    try await rig.journal.journalNoteNewAssetAsync(assetID: "b", newAssetID: "ghost")
    // c: a real prepared pair, left verified
    let batch = await prepared(rig, ["c"])
    // d: copy exists but was never verified -> orphan
    rig.library.configure { $0.tamperCopy = { $0.fp.isHidden = true } }
    _ = await rig.flow.prepare([rig.item("d")])
    // e: verified, but the original was deleted behind our back -> finished
    rig.library.configure { $0.tamperCopy = nil }
    _ = await prepared(rig, ["e"])
    rig.library.remove("e")

    let rec = try await rig.flow.reconcile()
    #expect(try await rig.state("a") == .discarded)
    #expect(try await rig.state("b") == .discarded)
    #expect(try await rig.state("e") == .committed)
    #expect(rec.pending == batch)
    #expect(rec.orphans.map(\.assetID) == ["d"])
    // The pending pair can be committed after relaunch; the orphan can be discarded.
    let result = try await rig.flow.retryDelete(rec.pending)
    #expect(result.deleted.map(\.assetID) == ["c"])
    try await rig.flow.discardCopy(newAssetId: rec.orphans[0].newAssetID)
    let again = try await rig.flow.reconcile()
    #expect(again.pending.isEmpty && again.orphans.isEmpty)
  }

  // MARK: Cancellation and background

  @Test func cancellingDuringTheDownloadCleansUpAndCreatesNothing() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    rig.library.configure { $0.export = .hangUntilCancelled }
    let flow = rig.flow, items = [rig.item("a"), rig.item("b")]
    let task = Task { await flow.prepare(items) }
    while !rig.library.calls.contains("export:a") { try await Task.sleep(for: .milliseconds(5)) }
    task.cancel()
    let report = await task.value
    #expect(report.cancelled && report.prepared.isEmpty && report.failures.isEmpty)
    #expect(!rig.library.calls.contains { $0.hasPrefix("create") })
    #expect(!rig.library.calls.contains("export:b"), "no further items after a cancel")
    #expect(rig.leftovers.isEmpty)
    #expect(try await rig.state("a") == nil)
  }

  @Test func backgroundTimeIsRequestedPerItem() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let ok = await rig.flow.prepare([rig.item("a"), rig.item("b")])
    #expect(ok.prepared.count == 2)
    #expect(rig.background.began == 2 && rig.background.ended == 2)
  }

  @Test func expiryDuringDownloadCancelsTheItemCleanly() async throws {
    let rig = try Rig(ids: ["c", "d"]); defer { rig.cleanUp() }
    rig.library.configure { $0.export = .hangUntilCancelled }
    let background = rig.background
    rig.library.configure { $0.onExport = { Task { try? await Task.sleep(for: .milliseconds(20)); background.expire() } } }
    let report = await rig.flow.prepare([rig.item("c"), rig.item("d")])
    #expect(report.cancelled)
    #expect(!rig.library.calls.contains("export:d"))
    #expect(rig.background.began == rig.background.ended)
    #expect(rig.leftovers.isEmpty)
  }

  @Test func anItemThatFinishesAfterExpiryStillStopsTheBatch() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    let background = rig.background
    // Expire once the copy exists: from here the item can no longer be cancelled and completes normally.
    rig.library.configure { $0.onCreated = { background.expire() } }
    let report = await rig.flow.prepare([rig.item("a"), rig.item("b")])
    #expect(report.prepared.map(\.assetID) == ["a"], "the finished item is kept")
    #expect(report.cancelled)
    #expect(!rig.library.calls.contains("export:b"), "the batch stops")
    #expect(rig.background.began == rig.background.ended)
  }

  // MARK: Housekeeping

  @Test func staleScratchFilesAreSweptOnInit() throws {
    let root = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: root) }
    let stale = root.appendingPathComponent("stale")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)
    _ = ReplaceFlow(gateway: FakeLibrary(source: Sample.photo), journal: Repositories(try AppDatabase.inMemory()),
                    workspace: SquishWorkspace(root: root), space: SquishDiskSpace(available: { 0 }),
                    background: NoBackgroundExecution(), allowNetwork: false)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
  }

  @Test func plannerSkipsCopiesRollMadeItself() async throws {
    let rig = try Rig(); defer { rig.cleanUp() }
    _ = await rig.flow.prepare([rig.item("a")])
    let copies = try await rig.journal.journaledCopyIDs()
    var record = AssetRecordFixtures.video(bytes: 400_000_000, seconds: 10)
    record.id = "new-1"
    var other = record; other.id = "z"
    let plan = SquishPlanner.plan(records: [record, other], keep4K: false, excluding: copies)
    #expect(plan.map(\.assetID) == ["z"])
  }
}

@Suite(.enabled(if: Fixtures.hasHEVCHardwareEncoder, "no HEVC hardware encoder on this host"))
struct ReplaceFlowVideoTests {
  @Test func aVideoRoundTripsThroughTheFlow() async throws {
    let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("v.mov")
    try await Fixtures.makeVideo(at: src, audio: true)
    let rig = try Rig(source: src, width: 640, height: 360, ids: []); defer { rig.cleanUp() }
    rig.library.addVideo("v")
    let report = await rig.flow.prepare([rig.item("v")])
    let p = try #require(report.prepared.first, "failures: \(report.failures)")
    #expect(p.newBytes < p.originalBytes)
    #expect(rig.library.asset("new-1")?.stored?.uti == "com.apple.quicktime-movie")
    let result = try await rig.flow.commitDeletes(report.prepared)
    #expect(result.deleted.count == 1)
  }
}

struct FingerprintTests {
  private let base = AssetFingerprint(isVideo: false, duration: 0, pixelWidth: 10, pixelHeight: 10,
                                      creationDate: Date(timeIntervalSince1970: 1000), modificationDate: nil, isFavorite: true,
                                      isHidden: false, latitude: 1, longitude: 2, albumIDs: ["A"])

  @Test func identicalMatches() { #expect(AssetFingerprint.mismatch(source: base, new: base, keep4K: false) == nil) }

  @Test func nilCreationDateFailsUnlessTheSourceHadNone() {
    var n = base; n.creationDate = nil
    #expect(AssetFingerprint.mismatch(source: base, new: n, keep4K: false) == "creation date missing")
    var s = base; s.creationDate = nil
    #expect(AssetFingerprint.mismatch(source: s, new: n, keep4K: false) == nil)
    #expect(AssetFingerprint.mismatch(source: s, new: base, keep4K: false) == nil)
  }

  @Test func eachPreservedPropertyIsChecked() {
    func change(_ f: (inout AssetFingerprint) -> Void) -> String? {
      var n = base; f(&n); return AssetFingerprint.mismatch(source: base, new: n, keep4K: false)
    }
    #expect(change { $0.creationDate = Date(timeIntervalSince1970: 2000) } == "creation date differs")
    #expect(change { $0.isFavorite = false } == "favorite state differs")
    #expect(change { $0.isHidden = true } == "hidden state differs")
    #expect(change { $0.latitude = nil } == "location missing")
    #expect(change { $0.longitude = 3 } == "location differs")
    #expect(change { $0.albumIDs = [] } == "album membership differs")
    #expect(change { $0.albumIDs = ["A", "B"] } == nil, "extra albums are fine")
    #expect(change { $0.pixelWidth = 0 } == "new asset has no pixels")
    #expect(change { $0.isVideo = true } == "media type differs")
  }

  @Test func videoDurationMustMatch() {
    var s = base; s.isVideo = true; s.duration = 10
    var n = s; n.duration = 10.05
    #expect(AssetFingerprint.mismatch(source: s, new: n, keep4K: false) == nil)
    n.duration = 10.5
    #expect(AssetFingerprint.mismatch(source: s, new: n, keep4K: false) == "duration differs")
  }
}
