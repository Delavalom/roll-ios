import Foundation
import GRDB
import Testing
@testable import Store

/// v12: scene labels per photo (`assetTag`, `assetTagRead`), `commitTags`, the pass's candidates, `tagLabels`, and the
/// tag generation `RankingChanges` counts apart from the candidate rows'.
struct TagTests {
  static let rev = "tag-rev"

  private func repo(_ assets: [AssetRecord]) async throws -> Repositories {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.replaceAssetsForTesting(assets)
    return repo
  }

  private func count(_ repo: Repositories, _ table: String) async throws -> Int {
    try await repo.database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }

  private func tags(_ id: String, _ labels: [(String, Double)], side: Int? = 360, revision: String = rev) -> TagFields {
    TagFields(id: id, labels: labels.map { TagLabel(label: $0.0, confidence: $0.1) }, revision: revision, side: side)
  }

  @Test func commitTagsTouchesOnlyTheTagTablesAndReplacesEarlierLabels() async throws {
    var gone = Fixtures.asset("gone")
    gone.deleted = true
    let repo = try await repo([Fixtures.asset("a", created: 1, embedded: true, signalsDone: true), gone])
    let before = try #require(try await repo.asset(id: "a"))
    try await repo.commitTags([tags("a", [("dog", 0.9), ("grass", 0.2)]), tags("gone", [("cat", 0.9)]),
                               tags("unknown", [("cat", 0.9)])])
    #expect(try await repo.asset(id: "a") == before)
    #expect(try await repo.tags(assetId: "a") == [TagLabel(label: "dog", confidence: 0.9),
                                                  TagLabel(label: "grass", confidence: 0.2)])
    #expect(try await repo.tags(assetId: "gone").isEmpty)
    try await repo.commitTags([tags("a", [("beach", 0.5)])])
    #expect(try await repo.tags(assetId: "a") == [TagLabel(label: "beach", confidence: 0.5)])
    #expect(try await count(repo, "assetTagRead") == 1)
  }

  @Test func tagLabelsKeepsWhatClearsTheConfidenceForLivePhotos() async throws {
    let repo = try await repo([Fixtures.asset("a"), Fixtures.asset("b"), Fixtures.asset("c")])
    try await repo.commitTags([tags("a", [("dog", 0.9), ("grass", 0.2)]), tags("b", [("sky", 0.12)]),
                               tags("c", [("cake", 0.4)])])
    try await repo.markDeleted(["c"])
    #expect(try await repo.tagLabels(minConfidence: 0.3) == ["a": ["dog"]])
    let all = try await repo.tagLabels(minConfidence: 0.1)
    #expect(Set(all.keys) == ["a", "b"] && Set(all["a"] ?? []) == ["dog", "grass"])
  }

  @Test func candidatesAreAnalysedUnreadPhotosNewestFirstAndUnreadOnesComeBackWithTheNetwork() async throws {
    var video = Fixtures.asset("video", created: 9, signalsDone: true)
    video.mediaType = 2
    var gone = Fixtures.asset("gone", created: 10, signalsDone: true)
    gone.deleted = true
    let repo = try await repo([Fixtures.asset("old", created: 1, signalsDone: true),
                               Fixtures.asset("new", created: 3, signalsDone: true),
                               Fixtures.asset("pending", created: 4), gone, video,
                               Fixtures.asset("read", created: 5, signalsDone: true),
                               Fixtures.asset("stale", created: 6, signalsDone: true),
                               Fixtures.asset("unread", created: 7, signalsDone: true)])
    try await repo.commitTags([tags("read", [("dog", 0.5)]), tags("stale", [], revision: "old-rev"),
                               tags("unread", [], side: nil)])
    #expect(try await repo.tagCandidateIds(revision: Self.rev, retryUnread: false, limit: 10)
      == ["video", "stale", "new", "old"])
    #expect(try await repo.tagCandidateIds(revision: Self.rev, retryUnread: true, limit: 2) == ["video", "unread"])
    #expect(try await repo.tagCandidateCount(revision: Self.rev, retryUnread: false) == 4)
    #expect(try await repo.tagCandidateCount(revision: Self.rev, retryUnread: true) == 5)
  }

  @Test func deletedAndEditedPhotosDropTheirTags() async throws {
    let repo = try await repo([Fixtures.asset("a"), Fixtures.asset("b", signalsDone: true), Fixtures.asset("c"),
                               Fixtures.asset("d")])
    try await repo.commitTags(["a", "b", "c", "d"].map { tags($0, [("dog", 0.9)]) })
    try await repo.markDeleted(["a"])
    try await repo.resetForContentChange(ids: ["b"])
    try await repo.recordApplied([], deletedAssetIds: ["c"])
    #expect(try await repo.tagLabels(minConfidence: 0.1) == ["d": ["dog"]])
    try await repo.database.writer.write { db in try db.execute(sql: "DELETE FROM asset WHERE id = 'd'") }
    #expect(try await count(repo, "assetTag") == 0)
    #expect(try await count(repo, "assetTagRead") == 0)
  }

  @Test func tagWritesMoveTheTagGenerationNotTheRows() async throws {
    let repo = try await repo([Fixtures.asset("a")])
    let changes = try await repo.observeRankingChanges()
    let (rows, tagRows) = (changes.generation, changes.tagGeneration)
    try await repo.commitTags([tags("a", [("dog", 0.9)])])
    #expect(changes.generation == rows && changes.tagGeneration > tagRows)
    let afterTags = changes.tagGeneration
    try await repo.markEmbedded(ids: ["a"])
    #expect(changes.generation > rows && changes.tagGeneration == afterTags)
  }
}
