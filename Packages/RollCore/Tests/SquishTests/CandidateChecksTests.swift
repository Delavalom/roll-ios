import Foundation
import Overview
import Store
import Synchronization
import Testing
@testable import Squish
import SquishBridge

/// The checks that follow indexing (where originals are, local videos' formats) run once the type lookups have
/// drained, off the indexing task, one round at a time, and a repeat round only checks what's new: on a 30k library
/// re-running the whole stack every 1,000 type lookups reached thermal "serious" within a minute of launch.
struct CandidateChecksTests {
  static func shot(_ id: String, bytes: Int64 = 2_000_000) -> AssetRecord {
    AssetRecord(id: id, mediaType: 1, subtypes: 1 << 2, pixelW: 1284, pixelH: 2778, uti: "public.png",
                estBytes: bytes, signalsDone: true, source: .full, previewSide: 300)
  }

  /// A big local-or-not video Squish offers; its locality isn't checked yet.
  static func video(_ id: String) -> AssetRecord {
    AssetRecord(id: id, mediaType: 2, subtypes: 0, pixelW: 1920, pixelH: 1080, duration: 120,
                estBytes: 150_000_000, signalsDone: true, source: .full, previewSide: 300)
  }

  /// Answers `local` (true or false); `gate`, when set, holds every call until it's opened; `hung` ids never answer.
  final class Checker: LocalityChecking {
    let local: Set<String>
    let hung: Set<String>
    private let calls = Mutex<[String]>([])
    private let waiting = Mutex<[CheckedContinuation<Bool?, Never>]>([])
    let gate = Mutex<Bool>(false)
    init(local: Set<String>, hung: Set<String> = [], gated: Bool = false) {
      self.local = local; self.hung = hung; gate.withLock { $0 = gated }
    }
    var checked: [String] { calls.withLock { $0 } }
    func isLocal(_ record: AssetRecord) async -> Bool? {
      calls.withLock { $0.append(record.id) }
      while gate.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
      guard hung.contains(record.id) else { return local.contains(record.id) }
      return await withCheckedContinuation { c in waiting.withLock { $0.append(c) } }
    }
    func release() { waiting.withLock { $0 }.forEach { $0.resume(returning: true) } }
  }

  final class Probe: VideoFormatProbing {
    let hung: Set<String>
    private let calls = Mutex<[String]>([])
    private let waiting = Mutex<[CheckedContinuation<VideoFormatVerdict?, Never>]>([])
    init(hung: Set<String> = []) { self.hung = hung }
    var probed: [String] { calls.withLock { $0 } }
    func verdict(for assetID: String) async -> VideoFormatVerdict? {
      calls.withLock { $0.append(assetID) }
      guard hung.contains(assetID) else { return .squishable }
      return await withCheckedContinuation { c in waiting.withLock { $0.append(c) } }
    }
    func release() { waiting.withLock { $0 }.forEach { $0.resume(returning: .squishable) } }
  }

  static func checks(_ repo: Repositories, _ checker: Checker, _ probe: Probe,
                     timeout: Duration = .seconds(5)) -> CandidateChecks {
    CandidateChecks(repositories: repo,
                    locality: LocalityScanner(repositories: repo, checker: checker, timeout: timeout),
                    formats: SquishFormatScreen(probe: probe, repositories: repo, timeout: timeout))
  }

  @Test func aRoundChecksHomesAndSquishsCandidatesThenTheVideosFoundLocal() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("shot"), Self.video("v")])
    let checker = Checker(local: ["shot", "v"]), probe = Probe()
    let outcome = await Self.checks(repo, checker, probe).run(homeCandidates: ["shot"])
    #expect(Set(checker.checked) == ["shot", "v"], "Home's candidates plus Squish's")
    #expect(outcome?.locality.local == 2)
    #expect(probe.probed == ["v"], "found on this iPhone in this round, so probed in it too")
    #expect(outcome?.formats.recorded == 1 && outcome?.changed == true)
    #expect(try await repo.passedVideoProbes() == ["v"])
  }

  @Test func withoutHomesCandidatesTheyAreComputed() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("shot")])
    let checker = Checker(local: [])
    let outcome = await Self.checks(repo, checker, Probe()).run(homeCandidates: nil)
    #expect(checker.checked == ["shot"])
    #expect(outcome?.locality.iCloud == 1)
  }

  @Test func aSecondRoundOnlyChecksWhatIsNew() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("shot"), Self.video("v")])
    let checker = Checker(local: ["shot", "v"]), probe = Probe()
    let checks = Self.checks(repo, checker, probe)
    _ = await checks.run(homeCandidates: ["shot"])
    let again = await checks.run(homeCandidates: ["shot"])
    #expect(checker.checked.count == 2 && probe.probed.count == 1, "nothing is checked twice in a launch")
    #expect(again?.changed == false, "Home isn't asked to rescan for nothing")
  }

  @Test func callsDuringARoundFoldIntoOneMoreRound() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.upsertAssets([Self.shot("a"), Self.shot("b")])
    let checker = Checker(local: ["a", "b"], gated: true)
    let checks = Self.checks(repo, checker, Probe())
    let first = Task { await checks.run(homeCandidates: ["a"]) }
    while checker.checked.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await checks.run(homeCandidates: ["a"]) == nil, "folded into the running round's follow-up")
    #expect(await checks.run(homeCandidates: ["a", "b"]) == nil)
    checker.gate.withLock { $0 = false }
    let outcome = await first.value
    #expect(outcome?.rounds == 2, "one follow-up for both calls, with the latest candidates")
    #expect(checker.checked == ["a", "b"])
  }

  @Test func callbacksThatNeverComeCanNotHoldTheRoundUp() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var local = Self.video("local")
    local.originalLocal = true
    try await repo.upsertAssets([Self.shot("shot"), local])
    let checker = Checker(local: [], hung: ["shot", "local"]), probe = Probe(hung: ["local"])
    let outcome = await Self.checks(repo, checker, probe, timeout: .milliseconds(30)).run(homeCandidates: ["shot"])
    #expect(outcome?.locality.timedOut == 2 && outcome?.formats.timedOut == 1)
    #expect(try await repo.asset(id: "shot")?.locality == .unknown)
    checker.release()
    probe.release()
  }
}
