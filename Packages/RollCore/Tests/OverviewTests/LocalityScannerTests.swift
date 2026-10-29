import Foundation
import Overview
import Ranking
import Store
import Synchronization
import Testing

/// Locality is checked on the original resource for the items that matter (the headline's and Squish's candidates),
/// not-yet-checked ones first, largest first, within a budget; known ones are re-checked after (iOS may offload them).
struct LocalityScannerTests {
  final class FakeChecker: LocalityChecking {
    let local: Set<String>
    let unanswered: Set<String>
    private let calls = Mutex<[String]>([])
    init(local: Set<String>, unanswered: Set<String> = []) { self.local = local; self.unanswered = unanswered }
    var checked: [String] { calls.withLock { $0 } }
    func isLocal(_ record: AssetRecord) async -> Bool? {
      calls.withLock { $0.append(record.id) }
      return unanswered.contains(record.id) ? nil : local.contains(record.id)
    }
  }

  static func shot(_ id: String, bytes: Int64, local: Bool? = nil) -> AssetRecord {
    var r = Make.asset(id, subtypes: Preset.screenshotSubtype, bytes: bytes)
    r.originalLocal = local
    return r
  }

  @Test func theSummaryListsEveryCandidateLargestFirstWhateverItsLocality() {
    let s = CleanupSummary.make(records: [Self.shot("a", bytes: 100), Self.shot("b", bytes: 300, local: false),
                                          Self.shot("c", bytes: 200, local: true), Make.asset("plain", bytes: 999)],
                                groups: [])
    #expect(s.localityCandidates == ["b", "c", "a"], "only cleanup candidates, not every asset")
  }

  @Test func uncheckedFirstLargestFirstWithinTheBudget() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("u1", bytes: 100), Self.shot("u2", bytes: 300), Self.shot("k", bytes: 900, local: true),
                                 Self.shot("x", bytes: 200)])
    let checker = FakeChecker(local: ["u2"], unanswered: ["x"])
    let result = try await LocalityScanner(repositories: repo, checker: checker, budget: 3).scan(["u1", "u2", "k", "x"])
    #expect(checker.checked == ["u2", "x", "u1"], "unchecked first, largest first; the known one waits")
    #expect(result == LocalityScanner.Result(checked: 3, local: 1, iCloud: 1, unanswered: 1))
    let rows = try await repo.assets(ids: ["u1", "u2", "k", "x"])
    #expect(rows.map(\.locality) == [.iCloud, .onDevice, .onDevice, .unknown])
  }

  @Test func knownItemsAreReCheckedAndOffloadedOnesMoveToICloud() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("a", bytes: 100, local: true), Self.shot("b", bytes: 300, local: true)])
    let checker = FakeChecker(local: ["a"])
    let result = try await LocalityScanner(repositories: repo, checker: checker).scan(["a", "b"])
    #expect(checker.checked == ["b", "a"])
    #expect(result.iCloud == 1)
    #expect(try await repo.asset(id: "b")?.locality == .iCloud)
    let s = CleanupSummary.make(records: try await repo.liveAssetsSlim(), groups: [])
    #expect(s.freeableOnDevice == 100 && s.freeableInCloud == 300)
  }

  /// Answers like `FakeChecker`, except for `hung` ids: those never call back (like a PhotoKit request whose handler
  /// never fires). Their continuations are held, so nothing leaks mid-test.
  final class HangingChecker: LocalityChecking {
    let local: Set<String>
    let hung: Set<String>
    private let calls = Mutex<[String]>([])
    private let waiting = Mutex<[CheckedContinuation<Bool?, Never>]>([])
    init(local: Set<String> = [], hung: Set<String>) { self.local = local; self.hung = hung }
    var checked: [String] { calls.withLock { $0 } }
    func isLocal(_ record: AssetRecord) async -> Bool? {
      calls.withLock { $0.append(record.id) }
      guard hung.contains(record.id) else { return local.contains(record.id) }
      return await withCheckedContinuation { c in waiting.withLock { $0.append(c) } }
    }
    /// Late answers ("on the device"): they must be ignored.
    func releaseAsLocal() { waiting.withLock { $0 }.forEach { $0.resume(returning: true) } }
  }

  @Test func aCheckThatNeverAnswersTimesOutAndCountsAsNotChecked() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("hung", bytes: 900), Self.shot("ok", bytes: 100)])
    let checker = HangingChecker(local: ["ok"], hung: ["hung"])
    let scanner = LocalityScanner(repositories: repo, checker: checker, timeout: .milliseconds(50))
    let result = try await scanner.scan(["hung", "ok"])
    #expect(checker.checked == ["hung", "ok"], "the scan goes on past the hung check")
    #expect(result == LocalityScanner.Result(checked: 2, local: 1, iCloud: 0, unanswered: 1, timedOut: 1))
    checker.releaseAsLocal()
    #expect(try await repo.asset(id: "hung")?.locality == .unknown, "never on-device: unknown counts as iCloud")
    #expect(try await repo.asset(id: "ok")?.locality == .onDevice)
  }

  @Test func repeatedTimeoutsEndTheScan() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    let ids = (0..<6).map { "h\($0)" }
    try await repo.upsertAssets(ids.enumerated().map { Self.shot($1, bytes: Int64(100 - $0)) })
    let checker = HangingChecker(hung: Set(ids))
    let scanner = LocalityScanner(repositories: repo, checker: checker, timeout: .milliseconds(20))
    let result = try await scanner.scan(ids)
    #expect(checker.checked.count == LocalityScanner.maxConsecutiveTimeouts, "PhotoKit isn't answering: stop asking")
    #expect(result.timedOut == LocalityScanner.maxConsecutiveTimeouts && result.local == 0)
    checker.releaseAsLocal()
  }

  @Test func eachItemIsCheckedAtMostOncePerWindow() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("known", bytes: 900, local: true), Self.shot("new", bytes: 100),
                                 Self.shot("silent", bytes: 50)])
    let checker = FakeChecker(local: ["known", "new"], unanswered: ["silent"])
    let scanner = LocalityScanner(repositories: repo, checker: checker)
    _ = try await scanner.scan(["known", "new", "silent"])
    #expect(checker.checked == ["new", "silent", "known"], "unchecked first, then the known one, once")
    let again = try await scanner.scan(["known", "new", "silent"])
    #expect(again.checked == 0 && checker.checked.count == 3, "nothing is re-checked within the hour, answered or not")
    try await repo.upsertAssets([Self.shot("later", bytes: 10)])
    _ = try await scanner.scan(["known", "new", "silent", "later"])
    #expect(checker.checked.last == "later" && checker.checked.count == 4, "only the newcomer")
  }

  @Test func afterTheWindowKnownItemsAreCheckedAgain() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("a", bytes: 100, local: true)])
    let checker = FakeChecker(local: ["a"])
    let scanner = LocalityScanner(repositories: repo, checker: checker, recheckAfter: .zero)
    _ = try await scanner.scan(["a"])
    _ = try await scanner.scan(["a"])
    #expect(checker.checked == ["a", "a"])
    #expect(LocalityScanner.defaultRecheckAfter == .seconds(3_600))
  }
}
