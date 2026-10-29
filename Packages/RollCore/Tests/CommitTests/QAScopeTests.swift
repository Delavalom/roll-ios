#if DEBUG
import Foundation
import Synchronization
import Testing
import Entitlements
import Store
@testable import Commit

/// A QA album that can change between checks, like the real one (the gate must re-read it every time).
final class FakeQAAlbum: Sendable {
  private let state: Mutex<QAAlbumLookup>
  private let reads = Mutex(0)
  init(_ lookup: QAAlbumLookup) { state = Mutex(lookup) }
  func set(_ lookup: QAAlbumLookup) { state.withLock { $0 = lookup } }
  var readCount: Int { reads.withLock { $0 } }
  func gate(limit: Int = QAAlbumGate.defaultLimit) -> QAAlbumGate {
    QAAlbumGate(title: "Roll QA", limit: limit) { _ in
      self.reads.withLock { $0 += 1 }
      return self.state.withLock { $0 }
    }
  }
}

/// The DEBUG `-QAAlbum` gate: pure membership rules, then the committer with the gate in front of the fake library.
struct QAScopeTests {
  @Test func allowsOnlyMembersAndReReadsTheAlbumEachTime() async throws {
    let album = FakeQAAlbum(.found(["a", "b"]))
    let gate = album.gate()
    try await gate.check(["a", "b", "a"], for: .delete)
    await #expect(throws: QAScopeViolation.notInAlbum(title: "Roll QA", operation: .delete, refused: 1, of: 2)) {
      try await gate.check(["a", "x"], for: .delete)
    }
    album.set(.found(["a"]))
    await #expect(throws: QAScopeViolation.notInAlbum(title: "Roll QA", operation: .squish, refused: 1, of: 1)) {
      try await gate.check(["b"], for: .squish)
    }
    #expect(album.readCount == 3, "no caching: every check looks the album up again")
  }

  @Test func refusesAMissingAmbiguousOrOversizedAlbum() async throws {
    await #expect(throws: QAScopeViolation.albumMissing(title: "Roll QA")) {
      try await FakeQAAlbum(.missing).gate().check(["a"], for: .delete)
    }
    await #expect(throws: QAScopeViolation.albumAmbiguous(title: "Roll QA", count: 2)) {
      try await FakeQAAlbum(.ambiguous(count: 2)).gate().check(["a"], for: .delete)
    }
    let big = Set((0..<81).map { "a\($0)" })
    await #expect(throws: QAScopeViolation.albumTooLarge(title: "Roll QA", count: 81, limit: 80)) {
      try await FakeQAAlbum(.found(big)).gate().check(["a0"], for: .delete)
    }
  }

  @Test func anEmptyRequestNeedsNoAlbum() async throws {
    let album = FakeQAAlbum(.missing)
    try await album.gate().check([], for: .delete)
    #expect(album.readCount == 0)
  }

  @Test func aReadOnlyRunRefusesEveryChange() async throws {
    let rig = try Rig()
    let library = FakeLibrary(log: rig.log)
    let plan = try await rig.plan(deletes: ["a"])
    let committer = PhotoKitCommitter(library: QAGatedCommitLibrary(base: library, gate: QAReadOnlyGate()), database: rig.db,
                                      pro: FixedPro(value: true), squish: nil)
    await #expect(throws: CommitFailure.self) { _ = try await committer.apply(plan) }
    #expect(library.deleteCalls.isEmpty)
    try await QAReadOnlyGate().check([], for: .delete)
  }

  @Test func violationsReadClearly() {
    let text = QAScopeViolation.notInAlbum(title: "Roll QA", operation: .delete, refused: 2, of: 5).description
    #expect(text == "QA scope: refused to delete: 2 of 5 items are not in \"Roll QA\".")
    #expect(QAScopeViolation.albumMissing(title: "Roll QA").localizedDescription.contains("no album named"))
  }

  // MARK: restock (-QARestock)

  @Test func restockRemovesOnlyAsManyICloudOnlyItemsAsNeeded() async {
    let local: Set = ["l1", "l2"]
    var asked: [String] = []
    let plan = await QARestockRoom.plan(albumCount: 40, incoming: 3, candidates: ["c1", "l1", "open", "c2", "c3", "c4"],
                                        protected: ["open"], limit: 40) { id in
      asked.append(id)
      return !local.contains(id)
    }
    #expect(plan == .remove(["c1", "c2", "c3"]))
    #expect(asked == ["c1", "l1", "c2", "c3"], "protected ids are never asked about, and it stops once there's room")
  }

  @Test func restockNeedsNoRoomBelowTheLimitAndCountsAnOverfullAlbum() async {
    #expect(QARestockRoom.needed(albumCount: 30, incoming: 5, limit: 40) == 0)
    #expect(QARestockRoom.needed(albumCount: 44, incoming: 5, limit: 40) == 9)
    let plan = await QARestockRoom.plan(albumCount: 35, incoming: 5, candidates: ["a"], protected: [], limit: 40) { _ in
      Issue.record("no locality check when there's room")
      return true
    }
    #expect(plan == .remove([]))
  }

  @Test func restockLeavesRoomForThePassAndClearsAnOverfullAlbumWithNothingStaged() async {
    #expect(QARestockRoom.limit + QARestockRoom.passHeadroom == QAAlbumGate.startLimit)
    #expect(QARestockRoom.needed(albumCount: 30, incoming: 5) == 3)
    // D3 left a copy in a full album (41): with nothing staged, restock still takes the album back to the limit.
    let plan = await QARestockRoom.plan(albumCount: 41, incoming: 0, candidates: (0..<20).map { "c\($0)" },
                                        protected: []) { _ in true }
    #expect(plan == .remove((0..<9).map { "c\($0)" }))
  }

  @Test func restockRefusesWhenItCantMakeRoom() async {
    // Unanswered (nil) and local (false) items stay in the album.
    let short = await QARestockRoom.plan(albumCount: 40, incoming: 2, candidates: ["a", "b", "c"], protected: [], limit: 40) {
      $0 == "a" ? true : $0 == "b" ? nil : false
    }
    #expect(short == .refused(needed: 2, found: 1))
    let tooMany = await QARestockRoom.plan(albumCount: 0, incoming: 41, candidates: [], protected: [], limit: 40) { _ in true }
    #expect(tooMany == .refused(needed: 1, found: 0))
  }

  @Test func theGateGuardsRemovalsFromTheQAAlbum() async throws {
    let gate = FakeQAAlbum(.found(["a"])).gate()
    try await gate.check(["a"], for: .removeFromQAAlbum)
    await #expect(throws: QAScopeViolation.notInAlbum(title: "Roll QA", operation: .removeFromQAAlbum, refused: 1, of: 1)) {
      try await gate.check(["x"], for: .removeFromQAAlbum)
    }
  }

  // MARK: committer

  struct Rig {
    let db: AppDatabase
    let repo: Repositories
    let log = CallLog()

    init() throws {
      db = try AppDatabase.inMemory()
      repo = Repositories(db)
    }

    func plan(deletes: [String], album: [String] = []) async throws -> CommitPlan {
      let sfs = [CF.swipefile("del"), CF.swipefile("alb", .album, name: "Keep", album: "Keep")]
      for sf in sfs { try await repo.save(sf) }
      try await repo.upsertAssets((deletes + album).map { CF.asset($0) })
      var queued: [DecisionRecord] = []
      for (i, id) in deletes.enumerated() { queued.append(CF.decision("del", id, .action, at: Double(i))) }
      for (i, id) in album.enumerated() { queued.append(CF.decision("alb", id, .action, at: Double(100 + i))) }
      for d in queued { try await repo.record(d) }
      let records = try await repo.assets(ids: deletes + album)
      return CommitPlanner.plan(queued: queued, records: CF.byId(records), swipefiles: CF.byId(sfs), isPro: true,
                                quotaRemaining: 0)
    }

    func committer(_ library: FakeLibrary, _ album: FakeQAAlbum, squish: (any SquishRunner)? = nil) -> PhotoKitCommitter {
      PhotoKitCommitter(library: QAGatedCommitLibrary(base: library, gate: album.gate()), database: db,
                        pro: FixedPro(value: true), squish: squish)
    }
  }

  @Test func theGatedCommitterDeletesMembersOnly() async throws {
    let rig = try Rig()
    let library = FakeLibrary(log: rig.log)
    let plan = try await rig.plan(deletes: ["a", "b"])
    let outcome = try await rig.committer(library, FakeQAAlbum(.found(["a", "b", "c"]))).apply(plan)
    guard case .applied(let report) = outcome else { Issue.record("expected applied"); return }
    #expect(report.deleted == ["a", "b"])
    #expect(library.deleteCalls == [["a", "b"]])
  }

  @Test func oneOutsiderStopsTheWholeChangeBeforeTheLibrary() async throws {
    let rig = try Rig()
    let library = FakeLibrary(log: rig.log)
    let plan = try await rig.plan(deletes: ["a", "outside"])
    do {
      _ = try await rig.committer(library, FakeQAAlbum(.found(["a"]))).apply(plan)
      Issue.record("expected the gate to refuse")
    } catch let failure as CommitFailure {
      #expect(failure.underlying as? QAScopeViolation
              == .notInAlbum(title: "Roll QA", operation: .delete, refused: 1, of: 2))
      #expect(failure.report.deleted.isEmpty)
    }
    #expect(library.deleteCalls.isEmpty && rig.log.all.isEmpty, "nothing reached the library")
    #expect(try await rig.repo.queued(for: "del").count == 2, "the queue stays as it was")
  }

  @Test func albumMovesAreGatedToo() async throws {
    let rig = try Rig()
    let library = FakeLibrary(log: rig.log)
    let plan = try await rig.plan(deletes: [], album: ["outside"])
    await #expect(throws: CommitFailure.self) {
      _ = try await rig.committer(library, FakeQAAlbum(.found(["a"]))).apply(plan)
    }
    #expect(library.albumCalls.isEmpty)
  }

  /// The album is looked up again before each 500-item chunk: if it disappears after the first, the second is refused.
  @Test func theAlbumVanishingMidRunStopsTheNextChunk() async throws {
    let rig = try Rig()
    let ids = (0..<600).map { String(format: "a%03d", $0) }
    let album = FakeQAAlbum(.found(Set(ids)))
    let base = FakeLibrary(log: rig.log)
    let plan = try await rig.plan(deletes: ids)
    let committer = PhotoKitCommitter(
      library: QAGatedCommitLibrary(base: DroppingLibrary(base: base, album: album), gate: album.gate(limit: 1_000)),
      database: rig.db, pro: FixedPro(value: true), squish: nil)
    do {
      _ = try await committer.apply(plan)
      Issue.record("expected the second chunk to be refused")
    } catch let failure as CommitFailure {
      #expect(failure.underlying as? QAScopeViolation == .albumMissing(title: "Roll QA"))
      #expect(failure.report.deleted.count == PhotoKitCommitter.deleteChunk)
    }
    #expect(base.deleteCalls.map(\.count) == [PhotoKitCommitter.deleteChunk])
    #expect(album.readCount == 2)
  }
}

/// Deletes through `base`, then makes the QA album disappear.
private struct DroppingLibrary: CommitLibrary {
  let base: FakeLibrary
  let album: FakeQAAlbum
  func delete(_ ids: [String]) async throws {
    try await base.delete(ids)
    album.set(.missing)
  }
  func addToAlbum(named name: String, _ ids: [String]) async throws { try await base.addToAlbum(named: name, ids) }
}
#endif
