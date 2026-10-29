import Foundation
import GRDB
import Testing
@testable import Store

/// v10: words read from images (`assetText` + the `assetTextFts` keyword index), `commitText`, `keywordCoverage`.
struct TextTests {
  static let rev = "test-rev"

  private func repo(_ assets: [AssetRecord]) async throws -> Repositories {
    let repo = Repositories(try AppDatabase.inMemory())
    try await repo.replaceAssetsForTesting(assets)
    return repo
  }

  private func text(_ id: String, _ text: String, side: Int? = 960, revision: String = rev) -> TextFields {
    TextFields(id: id, text: text, revision: revision, side: side)
  }

  // MARK: terms

  @Test func termsAreLowercasedFoldedSplitAndAtLeastTwoCharacters() {
    #expect(TextTerms.terms("Café  ÜBER-receipt #12 a @handle x9 Ñandú") ==
      ["cafe", "uber", "receipt", "12", "handle", "x9", "nandu"])
    #expect(TextTerms.terms("one one ONE") == ["one"], "unique, in first-seen order")
    #expect(TextTerms.terms("$116.42") == ["116", "42"])
    #expect(TextTerms.terms("— . a") == [])
  }

  // MARK: schema

  @Test func v10CreatesTheTextTablesWithAKeywordIndex() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.read { db in
      #expect(try db.columns(in: "assetText").map(\.name)
        == ["id", "assetId", "text", "terms", "revision", "side", "readAt"])
      let fts = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'assetTextFts'") ?? ""
      #expect(fts.contains("fts5") && fts.contains("porter unicode61 remove_diacritics 2"))
      let gated = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'asset_textGated'") ?? ""
      #expect(gated.contains(TextGate.candidateWhere), "the query's WHERE must match the partial index literally")
    }
  }

  // MARK: commitText

  @Test func commitTextTouchesOnlyTheTextTables() async throws {
    var a = Fixtures.asset("a", created: 1, embedded: true, signalsDone: true)
    a.isUtility = true
    let repo = try await repo([a])
    let before = try #require(try await repo.asset(id: "a"))
    try await repo.commitText([text("a", "Uber receipt")])
    #expect(try await repo.asset(id: "a") == before)
    let stored = try #require(try await repo.text(assetId: "a"))
    #expect(stored.text == "Uber receipt" && stored.terms == "uber receipt" && stored.revision == Self.rev)
    #expect(stored.side == 960)
  }

  @Test func commitTextReplacesEarlierWordsAndSkipsUnknownOrDeletedAssets() async throws {
    var gone = Fixtures.asset("gone")
    gone.deleted = true
    let repo = try await repo([Fixtures.asset("a"), gone])
    try await repo.commitText([text("a", "old words")])
    try await repo.commitText([text("a", "new words"), text("nobody", "ghost"), text("gone", "ghost")])
    #expect(try await repo.keywordCoverage(terms: ["old"]) == [:])
    #expect(try await repo.keywordCoverage(terms: ["new"]) == ["a": 1])
    #expect(try await repo.keywordCoverage(terms: ["ghost"]) == [:])
    #expect(try await repo.text(assetId: "nobody") == nil)
    #expect(try await repo.text(assetId: "gone") == nil)
  }

  // MARK: keywordCoverage

  @Test func coverageIsTheShareOfTermsFoundPerAsset() async throws {
    let repo = try await repo([Fixtures.asset("a"), Fixtures.asset("b"), Fixtures.asset("c")])
    try await repo.commitText([text("a", "UBER receipt Total 12.50"), text("b", "Receipt from Lyft"),
                               text("c", "nothing here")])
    let coverage = try await repo.keywordCoverage(terms: ["uber", "receipt"])
    #expect(coverage == ["a": 1, "b": 0.5])
    #expect(try await repo.keywordCoverage(terms: ["uber", "uber", "receipt"]) == coverage, "duplicate terms count once")
    #expect(try await repo.keywordCoverage(terms: []) == [:])
    #expect(try await repo.keywordCoverage(terms: ["12", "50"]) == ["a": 1])
  }

  @Test func coverageFoldsCaseAndDiacriticsAndStems() async throws {
    let repo = try await repo([Fixtures.asset("a"), Fixtures.asset("b")])
    try await repo.commitText([text("a", "Café Ñandú"), text("b", "Two RECEIPTS were printed")])
    #expect(try await repo.keywordCoverage(terms: ["cafe", "nandu"]) == ["a": 1])
    #expect(try await repo.keywordCoverage(terms: ["Café"]) == ["a": 1], "terms are normalised defensively")
    #expect(try await repo.keywordCoverage(terms: ["receipt"]) == ["b": 1], "Porter: receipt finds receipts")
    #expect(try await repo.keywordCoverage(terms: ["printing"]) == ["b": 1], "Porter: printing finds printed")
  }

  @Test func aTermOfThreeOrMoreCharactersInNoTextMatchesAsAPrefix() async throws {
    let repo = try await repo([Fixtures.asset("a"), Fixtures.asset("b"), Fixtures.asset("c")])
    try await repo.commitText([text("a", "Grokipedia @delavalom"), text("b", "my cat"), text("c", "category page")])
    #expect(try await repo.keywordCoverage(terms: ["grok"]) == ["a": 1], "not indexed whole: prefix")
    #expect(try await repo.keywordCoverage(terms: ["delaval"]) == ["a": 1])
    #expect(try await repo.keywordCoverage(terms: ["cat"]) == ["b": 1], "indexed whole: stays whole")
    #expect(try await repo.keywordCoverage(terms: ["gr"]) == [:], "two letters never become a prefix")
  }

  @Test func coverageCountsLiveAssetsOnly() async throws {
    let repo = try await repo([Fixtures.asset("a"), Fixtures.asset("b")])
    try await repo.commitText([text("a", "boarding pass"), text("b", "boarding pass")])
    try await repo.markDeleted(["b"])
    #expect(try await repo.keywordCoverage(terms: ["boarding"]) == ["a": 1])
  }

  @Test func coverageKeepsTheBestMatchesPerTermUpToTheLimit() async throws {
    let ids = (0..<5).map { "a\($0)" }
    let repo = try await repo(ids.map { Fixtures.asset($0) })
    // More occurrences rank higher (bm25), so a3 and a4 are the best two.
    try await repo.commitText(ids.enumerated().map { i, id in
      text(id, "total " + (i >= 3 ? "total total" : "words in a longer receipt line") )
    })
    let capped = try await repo.keywordCoverage(terms: ["total"], limitPerTerm: 2)
    #expect(Set(capped.keys) == ["a3", "a4"])
    #expect(try await repo.keywordCoverage(terms: ["total"]).count == 5)
    #expect(Repositories.keywordLimitPerTerm >= 1_000)
  }

  // MARK: cleanup

  @Test func deletedAndEditedAssetsDropTheirText() async throws {
    let repo = try await repo([Fixtures.asset("a"), Fixtures.asset("b", signalsDone: true), Fixtures.asset("c"),
                               Fixtures.asset("d")])
    try await repo.commitText(["a", "b", "c", "d"].map { text($0, "hello") })
    try await repo.markDeleted(["a"])
    try await repo.resetForContentChange(ids: ["b"])
    try await repo.recordApplied([], deletedAssetIds: ["c"])
    #expect(try await repo.text(assetId: "a") == nil)
    #expect(try await repo.text(assetId: "b") == nil, "an edit makes the words stale")
    #expect(try await repo.text(assetId: "c") == nil)
    #expect(try await repo.keywordCoverage(terms: ["hello"]) == ["d": 1])
    // Rows removed outright (UI-test reset) take their text with them, and the keyword index stays consistent.
    try await repo.database.writer.write { db in try db.execute(sql: "DELETE FROM asset WHERE id = 'd'") }
    #expect(try await repo.keywordCoverage(terms: ["hello"]) == [:])
    try await repo.database.writer.write { db in
      try db.execute(sql: "INSERT INTO assetTextFts(assetTextFts) VALUES('integrity-check')")
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assetText") == 0)
    }
  }

  @Test func resyncingALiveAssetKeepsItsText() async throws {
    let repo = try await repo([Fixtures.asset("a", signalsDone: true)])
    try await repo.commitText([text("a", "hello")])
    try await repo.upsertAssets([Fixtures.asset("a")])
    try await repo.commitSignals([SignalFields(id: "a", signalsDone: true, isUtility: true)])
    #expect(try await repo.keywordCoverage(terms: ["hello"]) == ["a": 1])
  }

  // MARK: gate and candidates

  @Test func theGateTakesScreenshotsAndUtilityImagesOnly() {
    #expect(TextGate.wantsText(mediaType: 1, subtypes: 4, isUtility: nil))
    #expect(TextGate.wantsText(mediaType: 1, subtypes: 4 | 8, isUtility: false))
    #expect(TextGate.wantsText(mediaType: 1, subtypes: 0, isUtility: true))
    #expect(!TextGate.wantsText(mediaType: 1, subtypes: 0, isUtility: false))
    #expect(!TextGate.wantsText(mediaType: 1, subtypes: 0, isUtility: nil))
    #expect(!TextGate.wantsText(mediaType: 2, subtypes: 4, isUtility: true), "videos are never read")
  }

  /// The SQL selection and the Swift gate agree on every combination.
  @Test func candidatesFollowTheGate() async throws {
    var rows: [AssetRecord] = []
    var expected: [String] = []
    var n = 0
    for mediaType in [1, 2] {
      for subtypes in [0, 4, 8, 12] {
        for isUtility in [nil, false, true] as [Bool?] {
          n += 1
          var r = Fixtures.asset("x\(n)", created: Double(n), signalsDone: true, mediaType: mediaType)
          r.subtypes = subtypes
          r.isUtility = isUtility
          rows.append(r)
          if TextGate.wantsText(mediaType: mediaType, subtypes: subtypes, isUtility: isUtility) { expected.append(r.id) }
        }
      }
    }
    let repo = try await repo(rows)
    let got = try await repo.textCandidateIds(revision: Self.rev, retryUnread: false, limit: 100)
    #expect(Set(got) == Set(expected))
    #expect(!expected.isEmpty)
  }

  @Test func candidatesAreLiveAnalysedGatedImagesWithoutTextAtThisRevisionNewestFirst() async throws {
    func shot(_ id: String, _ created: Double, signalsDone: Bool = true, deleted: Bool = false) -> AssetRecord {
      var r = Fixtures.asset(id, created: created, signalsDone: signalsDone)
      r.subtypes = 4
      r.deleted = deleted
      return r
    }
    let repo = try await repo([shot("old", 1), shot("new", 3), shot("mid", 2), shot("pending", 4, signalsDone: false),
                               shot("gone", 5, deleted: true), shot("read", 6), shot("stale", 7), shot("unread", 8)])
    try await repo.commitText([text("read", "x"), text("stale", "x", revision: "older"), text("unread", "", side: nil)])
    #expect(try await repo.textCandidateIds(revision: Self.rev, retryUnread: false, limit: 10)
      == ["stale", "new", "mid", "old"])
    #expect(try await repo.textCandidateIds(revision: Self.rev, retryUnread: true, limit: 10)
      == ["unread", "stale", "new", "mid", "old"], "a network pass retries images that couldn't be read")
    #expect(try await repo.textCandidateIds(revision: Self.rev, retryUnread: false, limit: 2) == ["stale", "new"])
    #expect(try await repo.textCandidateCount(revision: Self.rev, retryUnread: false) == 4)
  }
}
