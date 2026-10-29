import Foundation
import Testing
import Entitlements
import Store
@testable import Commit

/// The committer's ordering, chunking, cancel and quota rules, against a fake library and a real in-memory Store.
struct CommitterTests {
  let db: AppDatabase
  let repo: Repositories
  let quota: FreeQuota
  let log = CallLog()

  init() throws {
    db = try AppDatabase.inMemory()
    repo = Repositories(db)
    quota = FreeQuota(db)
  }

  /// Stores the swipefiles, assets and queued decisions, and plans them as Pro (so nothing is blocked).
  func seed(_ swipefiles: [SwipefileRecord], _ decisions: [(String, String)], verdict: Verdict = .action,
            mediaType: Int = 1) async throws -> CommitPlan {
    for sf in swipefiles { try await repo.save(sf) }
    let ids = Array(Set(decisions.map(\.1)))
    try await repo.upsertAssets(ids.map { CF.asset($0, bytes: 100, mediaType: mediaType) })
    var queued: [DecisionRecord] = []
    for (i, (sf, id)) in decisions.enumerated() {
      let d = CF.decision(sf, id, verdict, at: Double(i))
      try await repo.record(d)
      queued.append(d)
    }
    let records = try await repo.assets(ids: ids)
    return CommitPlanner.plan(queued: queued, records: CF.byId(records), swipefiles: CF.byId(swipefiles),
                              isPro: true, quotaRemaining: 0)
  }

  func committer(_ library: FakeLibrary, squish: (any SquishRunner)? = nil, pro: Bool = false) -> PhotoKitCommitter {
    PhotoKitCommitter(library: library, database: db, pro: FixedPro(value: pro), squish: squish)
  }

  func queuedIds(_ sf: String) async throws -> [String] { try await repo.queued(for: sf).map(\.assetId) }
  func isDeleted(_ id: String) async throws -> Bool { try await repo.asset(id: id)?.deleted ?? false }

  // MARK: deletes

  @Test func deletesGoInChunksOf500OnePromptEach() async throws {
    let ids = (0..<1_203).map { String(format: "a%04d", $0) }
    let plan = try await seed([CF.swipefile("sf")], ids.map { ("sf", $0) })
    let library = FakeLibrary(log: log)
    let outcome = try await committer(library, pro: true).apply(plan)

    #expect(library.deleteCalls.map(\.count) == [500, 500, 203])
    #expect(library.deleteCalls.joined().elementsEqual(ids))
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.deleted == ids)
    #expect(try await queuedIds("sf").isEmpty)
    #expect(try await isDeleted("a1202"))
    #expect(report.quotaSpent == 0, "Pro spends no quota")
    #expect(try await quota.remaining() == 50)
  }

  @Test func withoutProQuotaIsSpentAfterTheDeleteSucceeds() async throws {
    let plan = try await seed([CF.swipefile("sf")], [("sf", "a"), ("sf", "b"), ("sf", "c")])
    let outcome = try await committer(FakeLibrary(log: log)).apply(plan)
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.quotaSpent == 3)
    #expect(try await quota.remaining() == 47)
  }

  @Test func userCancelOnTheFirstPromptAppliesNothingAndSpendsNothing() async throws {
    let runner = FakeSquishRunner(log: log)
    let plan = try await seed([CF.swipefile("sf"), CF.swipefile("trip", .album, album: "Trip"), CF.swipefile("big", .squish)],
                              [("sf", "a"), ("trip", "b"), ("big", "c")])
    let library = FakeLibrary(log: log, script: [0: .userCancel])
    let outcome = try await committer(library, squish: runner).apply(plan)

    #expect(outcome == .cancelled(CommitReport()))
    #expect(log.all == ["delete:1"], "nothing after the declined prompt runs")
    #expect(try await queuedIds("sf") == ["a"])
    #expect(try await queuedIds("trip") == ["b"])
    #expect(try await queuedIds("big") == ["c"])
    #expect(try await isDeleted("a") == false)
    #expect(try await quota.remaining() == 50)
  }

  @Test func cancelOnALaterChunkKeepsTheChunksAlreadyConfirmed() async throws {
    let ids = (0..<520).map { String(format: "a%04d", $0) }
    let plan = try await seed([CF.swipefile("sf")], ids.map { ("sf", $0) })
    let library = FakeLibrary(log: log, script: [1: .userCancel])
    let outcome = try await committer(library, pro: true).apply(plan)

    guard case let .cancelled(report) = outcome else { Issue.record("expected cancelled"); return }
    #expect(report.deleted == Array(ids.prefix(500)))
    #expect(try await queuedIds("sf") == Array(ids.suffix(20)))
    #expect(try await isDeleted(ids[499]))
    #expect(try await isDeleted(ids[500]) == false)
  }

  @Test func aFailedChangeThrowsWithWhatAlreadySucceededAndCostsNothingForTheRest() async throws {
    let ids = (0..<501).map { String(format: "a%04d", $0) }
    let plan = try await seed([CF.swipefile("sf")], ids.map { ("sf", $0) })
    let library = FakeLibrary(log: log, script: [1: .fail])
    do {
      _ = try await committer(library).apply(plan)
      Issue.record("expected a failure")
    } catch let failure as CommitFailure {
      #expect(failure.underlying is TestError)
      #expect(failure.report.deleted.count == 500)
      #expect(failure.report.quotaSpent == 50, "the first chunk happened; the quota clamps at the limit")
    }
    #expect(try await queuedIds("sf") == [ids[500]])
    #expect(try await quota.remaining() == 0)
  }

  @Test func aQuotaRaceStillUsesUpWhatRemains() async throws {
    let plan = try await seed([CF.swipefile("sf")], [("sf", "a"), ("sf", "b"), ("sf", "c")])
    try await quota.consume(49)  // another commit spent it in the meantime
    let outcome = try await committer(FakeLibrary(log: log)).apply(plan)
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.deleted == ["a", "b", "c"], "the change already happened")
    #expect(report.quotaSpent == 1)
    #expect(try await quota.remaining() == 0)
  }

  @Test func aDeleteSettlesTheDecisionsItSuperseded() async throws {
    let plan = try await seed([CF.swipefile("sf"), CF.swipefile("trip", .album, album: "Trip")],
                              [("trip", "a"), ("sf", "a")])
    let library = FakeLibrary(log: log)
    _ = try await committer(library).apply(plan)
    #expect(library.albumCalls.isEmpty)
    #expect(try await queuedIds("sf").isEmpty)
    #expect(try await queuedIds("trip").isEmpty)
    #expect(try await quota.remaining() == 49)
  }

  // MARK: albums

  @Test func albumMovesRunAfterDeletesOnePerAlbumByName() async throws {
    let plan = try await seed([CF.swipefile("sf"), CF.swipefile("z", .album, album: "Zoo"), CF.swipefile("b", .album, album: "Beach")],
                              [("z", "z1"), ("sf", "d1"), ("b", "b1"), ("z", "z2")])
    let library = FakeLibrary(log: log)
    let outcome = try await committer(library).apply(plan)

    #expect(log.all == ["delete:1", "album:Beach:1", "album:Zoo:2"])
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.addedToAlbums == ["Beach": ["b1"], "Zoo": ["z1", "z2"]])
    #expect(try await queuedIds("z").isEmpty)
    #expect(try await isDeleted("z1") == false, "album moves keep the asset")
    #expect(report.quotaSpent == 4)
  }

  @Test func aCancelledAlbumChangeStopsTheRun() async throws {
    let runner = FakeSquishRunner(log: log)
    let plan = try await seed([CF.swipefile("a", .album, album: "A"), CF.swipefile("big", .squish)], [("a", "x"), ("big", "v")])
    let outcome = try await committer(FakeLibrary(log: log, script: [0: .userCancel]), squish: runner).apply(plan)
    #expect(outcome == .cancelled(CommitReport()))
    #expect(runner.prepareCalls.isEmpty)
    #expect(try await quota.remaining() == 50)
  }

  // MARK: squishes

  @Test func squishesPrepareTheWholeBatchThenDeleteOriginalsInOnePrompt() async throws {
    let runner = FakeSquishRunner(log: log)
    let plan = try await seed([CF.swipefile("sf"), CF.swipefile("big", .squish)],
                              [("big", "v1"), ("sf", "d"), ("big", "v2")], mediaType: 2)
    let library = FakeLibrary(log: log)
    let outcome = try await committer(library, squish: runner).apply(plan)

    #expect(log.all == ["delete:1", "squish.prepare:2", "squish.commit:2"])
    #expect(runner.prepareCalls == [[SquishRequest(assetID: "v1", estimatedBytes: 100), SquishRequest(assetID: "v2", estimatedBytes: 100)]])
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.squished.map(\.assetID) == ["v1", "v2"])
    #expect(report.estimatedSquishSavings == 1_200)
    #expect(try await queuedIds("big").isEmpty)
    #expect(try await isDeleted("v1"), "the original is gone; the copy arrives through the change observer")
    #expect(report.quotaSpent == 3)
  }

  @Test func failedAndVanishedSquishesStayQueuedAndCostNothing() async throws {
    let runner = FakeSquishRunner(log: log, failing: ["v2"], vanishing: ["v3"])
    let plan = try await seed([CF.swipefile("big", .squish)], [("big", "v1"), ("big", "v2"), ("big", "v3")], mediaType: 2)
    let outcome = try await committer(FakeLibrary(log: log), squish: runner).apply(plan)

    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(runner.commitCalls.map { $0.map(\.assetID) } == [["v1", "v3"]])
    #expect(report.squished.map(\.assetID) == ["v1"])
    #expect(report.squishSkipped.map(\.assetID) == ["v3"])
    #expect(report.squishFailures.map(\.assetID) == ["v2"])
    #expect(report.leftoverCopyIDs == ["left-v2"])
    #expect(try await queuedIds("big") == ["v2", "v3"])
    #expect(try await isDeleted("v3") == false)
    #expect(report.quotaSpent == 1)
  }

  @Test func decliningTheSquishPromptLeavesCopiesPendingAndSpendsNothingForThem() async throws {
    let runner = FakeSquishRunner(log: log, commit: .userCancel)
    let plan = try await seed([CF.swipefile("sf"), CF.swipefile("big", .squish)], [("sf", "d"), ("big", "v1")])
    let outcome = try await committer(FakeLibrary(log: log), squish: runner).apply(plan)

    guard case let .cancelled(report) = outcome else { Issue.record("expected cancelled"); return }
    #expect(report.deleted == ["d"], "the delete prompt was already confirmed")
    #expect(report.pendingSquishCopies.map(\.assetID) == ["v1"])
    #expect(report.squished.isEmpty)
    #expect(try await queuedIds("big") == ["v1"])
    #expect(try await isDeleted("v1") == false)
    #expect(try await quota.remaining() == 49)
  }

  @Test func retryingADeclinedSquishPromptRecordsAndChargesIt() async throws {
    let declined = FakeSquishRunner(log: log, commit: .userCancel)
    let plan = try await seed([CF.swipefile("big", .squish)], [("big", "v1"), ("big", "v2")])
    guard case let .cancelled(first) = try await committer(FakeLibrary(log: log), squish: declined).apply(plan) else {
      Issue.record("expected cancelled"); return
    }
    let runner = FakeSquishRunner(log: log)
    let outcome = try await committer(FakeLibrary(log: log), squish: runner).retrySquishDeletes(first.pendingSquishCopies, of: plan)
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(runner.prepareCalls.isEmpty, "the copies already exist")
    #expect(report.squished.map(\.assetID) == ["v1", "v2"])
    #expect(try await queuedIds("big").isEmpty)
    #expect(try await quota.remaining() == 48)
  }

  @Test func retryingWithoutProFinishesOnlyWhatTheFreeQuotaAllows() async throws {
    let plan = try await seed([CF.swipefile("big", .squish)], [("big", "v1"), ("big", "v2"), ("big", "v3")])
    try await quota.consume(FreeQuota.limit - 2)
    let pending = ["v1", "v2", "v3"].map { SquishedCopy(assetID: $0, newAssetID: "new-\($0)", originalBytes: 100, newBytes: 40) }
    let runner = FakeSquishRunner(log: log)
    guard case let .applied(report) = try await committer(FakeLibrary(log: log), squish: runner)
      .retrySquishDeletes(pending, of: plan) else { Issue.record("expected applied"); return }
    #expect(runner.commitCalls.map { $0.map(\.assetID) } == [["v1", "v2"]])
    #expect(report.squished.map(\.assetID) == ["v1", "v2"])
    #expect(report.squishBlockedByQuota.map(\.assetID) == ["v3"])
    #expect(try await quota.remaining() == 0)

    // Out of quota: nothing is asked or changed.
    let none = FakeSquishRunner(log: log)
    guard case let .applied(blocked) = try await committer(FakeLibrary(log: log), squish: none)
      .retrySquishDeletes(Array(pending.suffix(1)), of: plan) else { Issue.record("expected applied"); return }
    #expect(none.commitCalls.isEmpty)
    #expect(blocked.squishBlockedByQuota.map(\.assetID) == ["v3"] && blocked.squished.isEmpty)
    #expect(try await isDeleted("v3") == false)

    // Pro finishes everything.
    let pro = FakeSquishRunner(log: log)
    guard case let .applied(all) = try await committer(FakeLibrary(log: log), squish: pro, pro: true)
      .retrySquishDeletes(Array(pending.suffix(1)), of: plan) else { Issue.record("expected applied"); return }
    #expect(all.squished.map(\.assetID) == ["v3"] && all.squishBlockedByQuota.isEmpty)
  }

  @Test func discardingCopiesGoesThroughTheRunner() async throws {
    let runner = FakeSquishRunner(log: log)
    try await committer(FakeLibrary(log: log), squish: runner).discardCopies(["new-a", "new-b"])
    try await committer(FakeLibrary(log: log), squish: runner).discardCopies([])
    #expect(log.all == ["squish.discard:2"])
  }

  @Test func aCancelledPrepareNeverShowsTheSquishPrompt() async throws {
    let runner = FakeSquishRunner(log: log, cancelPrepare: true)
    let plan = try await seed([CF.swipefile("big", .squish)], [("big", "v1"), ("big", "v2")])
    let outcome = try await committer(FakeLibrary(log: log), squish: runner).apply(plan)

    guard case let .cancelled(report) = outcome else { Issue.record("expected cancelled"); return }
    #expect(runner.commitCalls.isEmpty)
    #expect(report.pendingSquishCopies.map(\.assetID) == ["v1"])
    #expect(try await queuedIds("big") == ["v1", "v2"])
    #expect(try await quota.remaining() == 50)
  }

  @Test func aFailedSquishDeleteThrowsAndKeepsTheCopiesPending() async throws {
    let runner = FakeSquishRunner(log: log, commit: .fail)
    let plan = try await seed([CF.swipefile("big", .squish)], [("big", "v1")])
    await #expect(throws: CommitFailure.self) { try await committer(FakeLibrary(log: log), squish: runner).apply(plan) }
    do { _ = try await committer(FakeLibrary(log: log), squish: runner).apply(plan) } catch let f as CommitFailure {
      #expect(f.report.pendingSquishCopies.map(\.assetID) == ["v1"])
    }
    #expect(try await queuedIds("big") == ["v1"])
    #expect(try await quota.remaining() == 50)
  }

  @Test func withoutASquishRunnerSquishesStayQueued() async throws {
    let plan = try await seed([CF.swipefile("sf"), CF.swipefile("big", .squish)], [("sf", "d"), ("big", "v")])
    let outcome = try await committer(FakeLibrary(log: log)).apply(plan)
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.squishUnavailable == ["v"])
    #expect(try await queuedIds("big") == ["v"])
    #expect(report.quotaSpent == 1)
  }

  @Test func anAssetMovedToAnAlbumAndSquishedCostsOneItem() async throws {
    let runner = FakeSquishRunner(log: log)
    let plan = try await seed([CF.swipefile("trip", .album, album: "Trip"), CF.swipefile("big", .squish)],
                              [("trip", "v"), ("big", "v")])
    let outcome = try await committer(FakeLibrary(log: log), squish: runner).apply(plan)
    #expect(log.all == ["album:Trip:1", "squish.prepare:1", "squish.commit:1"], "albums first, so the copy inherits them")
    guard case let .applied(report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.quotaSpent == 1)
    #expect(try await quota.remaining() == 49)
  }

  // MARK: bookkeeping

  @Test func staleDecisionsAreSettledForFree() async throws {
    try await repo.save(CF.swipefile("sf"))
    try await repo.upsertAssets([CF.asset("gone")])
    try await repo.markDeleted(["gone"])
    let d = CF.decision("sf", "gone")
    try await repo.record(d)
    let plan = CommitPlanner.plan(queued: [d], records: CF.byId(try await repo.assets(ids: ["gone"])),
                                  swipefiles: ["sf": CF.swipefile("sf")], isPro: false, quotaRemaining: 50)
    #expect(plan.isEmpty && plan.stale.count == 1)
    let outcome = try await committer(FakeLibrary(log: log)).apply(plan)
    #expect(outcome == .applied(CommitReport()))
    #expect(log.all.isEmpty)
    #expect(try await queuedIds("sf").isEmpty)
    #expect(try await quota.remaining() == 50)
  }

  @Test func aCancelledTaskTouchesNothing() async throws {
    let plan = try await seed([CF.swipefile("sf")], [("sf", "a")])
    let library = FakeLibrary(log: log)
    let c = committer(library)
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return try await c.apply(plan)
    }
    task.cancel()
    #expect(try await task.value == .cancelled(CommitReport()))
    #expect(log.all.isEmpty)
    #expect(try await queuedIds("sf") == ["a"])
  }

  @Test func progressReportsEachStep() async throws {
    let runner = FakeSquishRunner(log: log)
    let ids = (0..<501).map { String(format: "a%04d", $0) }
    let plan = try await seed([CF.swipefile("sf"), CF.swipefile("t", .album, album: "T"), CF.swipefile("big", .squish)],
                              ids.map { ("sf", $0) } + [("t", "x"), ("big", "v")])
    let progress = ProgressLog()
    _ = try await committer(FakeLibrary(log: log), squish: runner, pro: true).apply(plan) { progress.append($0) }
    #expect(progress.all == [
      .deleting(done: 0, total: 501), .deleting(done: 500, total: 501), .deleting(done: 501, total: 501),
      .addingToAlbum(name: "T"),
      .squishing(SquishRunProgress(assetID: "v", stage: .encoding, fraction: nil)),
      .deletingSquishedOriginals(count: 1),
    ])
  }
}
