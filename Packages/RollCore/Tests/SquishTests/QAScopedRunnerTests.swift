#if DEBUG
import Foundation
import Store
import Synchronization
import Testing
import Commit
@testable import Squish
import SquishBridge

/// The DEBUG `-QAAlbum` gate on the squish runner (ReplaceFlow over the fake library with real per-asset state).
@Suite(.enabled(if: Fixtures.canEncodeHEIC, "HEIC encoding is unavailable on this host"))
struct QAScopedRunnerTests {
  private static let photo: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-runner-\(UUID().uuidString).jpg")
    try! Fixtures.makeJPEG(at: url, width: 1600, height: 1200)
    return url
  }()

  /// A QA album whose members tests can change between calls.
  final class Album: Sendable {
    private let members: Mutex<Set<String>>
    init(_ ids: Set<String>) { members = Mutex(ids) }
    func set(_ ids: Set<String>) { members.withLock { $0 = ids } }
    func insert(_ id: String) { _ = members.withLock { $0.insert(id) } }
    var gate: QAAlbumGate { QAAlbumGate(title: "Roll QA") { _ in .found(self.members.withLock { $0 }) } }
  }

  final class Events: Sendable {
    private let items = Mutex<[String]>([])
    func add(_ e: String) { items.withLock { $0.append(e) } }
    var all: [String] { items.withLock { $0 } }
  }

  struct Rig {
    let library = FakeLibrary(source: QAScopedRunnerTests.photo)
    let repositories: Repositories
    let root: URL

    init(_ ids: [String]) throws {
      root = try Fixtures.tempDir()
      for id in ids { library.addPhoto(id) }
      repositories = Repositories(try AppDatabase.inMemory())
    }

    func runner(_ album: Album, hooks: QASquishHooks = QASquishHooks()) -> ReplaceFlowRunner {
      let flow = ReplaceFlow(gateway: library, journal: repositories, workspace: SquishWorkspace(root: root),
                             space: SquishDiskSpace(available: { 100_000_000_000 }), background: NoBackgroundExecution(),
                             allowNetwork: false)
      return ReplaceFlowRunner(flow: flow).qaScoped(gate: album.gate, hooks: hooks)
    }

    func requests(_ ids: [String]) -> [SquishRequest] { ids.map { SquishRequest(assetID: $0, estimatedBytes: 5_000_000) } }
  }

  @Test func aBatchWithAnOutsiderIsRefusedBeforeAnythingIsCreated() async throws {
    let rig = try Rig(["a", "outside"])
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let batch = await rig.runner(Album(["a"])).prepare(rig.requests(["a", "outside"]), progress: nil)
    #expect(batch.prepared.isEmpty)
    #expect(batch.failures.map(\.assetID) == ["a", "outside"])
    #expect(batch.failures.allSatisfy {
      ($0.error as? QAScopeViolation) == .notInAlbum(title: "Roll QA", operation: .squish, refused: 1, of: 2)
    })
    #expect(rig.library.calls.isEmpty, "the library wasn't touched")
    #expect(rig.library.copyIDs().isEmpty)
    if case .failed(let text) = SquishRefusal.classify(batch.failures[0].error) {
      #expect(text.hasPrefix("QA scope: refused to squish"))
    } else {
      Issue.record("the refusal should read as the QA message")
    }
  }

  @Test func theAlbumIsReadAgainRightBeforeTheDeleteAfterThePauseHook() async throws {
    let rig = try Rig(["a", "b"])
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let album = Album(["a", "b"])
    let events = Events()
    let hooks = QASquishHooks(
      prepared: { events.add("prepared:\($0.prepared.count)") },
      beforeCommitDeletes: { count in
        events.add("pause:\(count)")
        // "b" leaves the QA album while the first run is paused.
        if events.all.filter({ $0.hasPrefix("pause") }).count == 1 { album.set(["a"]) }
      },
      committed: { _ in events.add("committed") })
    let runner = rig.runner(album, hooks: hooks)
    let batch = await runner.prepare(rig.requests(["a", "b"]), progress: nil)
    #expect(batch.prepared.count == 2)
    for copy in batch.prepared { album.insert(copy.newAssetID) }  // createCopy adds copies to the original's albums

    await #expect(throws: QAScopeViolation.notInAlbum(title: "Roll QA", operation: .deleteSquishedOriginal, refused: 1, of: 2)) {
      _ = try await runner.commitDeletes(batch.prepared)
    }
    #expect(rig.library.has("a") && rig.library.has("b"), "no original was deleted")
    #expect(!rig.library.calls.contains { $0.hasPrefix("deleteGuarded") })
    #expect(events.all == ["prepared:2", "pause:2"])

    album.set(Set(["a", "b"] + batch.prepared.map(\.newAssetID)))
    let deletion = try await runner.commitDeletes(batch.prepared)
    #expect(deletion.deleted.map(\.assetID) == ["a", "b"])
    #expect(events.all.suffix(2) == ["pause:2", "committed"])
  }

  @Test func copiesOutsideTheAlbumAreNotDiscarded() async throws {
    let rig = try Rig(["a"])
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let album = Album(["a"])
    let runner = rig.runner(album)
    let batch = await runner.prepare(rig.requests(["a"]), progress: nil)
    let copy = try #require(batch.prepared.first?.newAssetID)
    await #expect(throws: QAScopeViolation.self) { try await runner.discardCopies([copy]) }
    #expect(rig.library.has(copy))
    album.insert(copy)
    try await runner.discardCopies([copy])
    #expect(!rig.library.has(copy))
  }
}
#endif
