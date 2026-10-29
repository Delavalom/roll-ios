import Foundation
import GRDB

/// Words read from images (Schema v10): the text pass writes them with `commitText`, typed search reads them with
/// `keywordCoverage`. Nothing here touches the `asset` table; the text of a deleted or edited asset goes by trigger.
extension Repositories {
  /// Best matches kept per term in `keywordCoverage` (by bm25). A common word ("the", "total") can match thousands of
  /// screenshots; a word that common says little about which one is meant, and the result stays small enough to merge
  /// with a vector search in a few milliseconds.
  public static let keywordLimitPerTerm = 1_000
  /// Terms after the first 16 (after normalising and removing duplicates) are ignored. The result therefore has at
  /// most 16,000 entries, and in practice no more than the number of images with text.
  public static let keywordMaxTerms = 16

  /// Stores the words read from each image (replacing earlier ones), in one transaction. Only the text tables change.
  /// Ids that are unknown or marked deleted are skipped: an asset deleted while it was being read keeps no text.
  public func commitText(_ items: [TextFields]) async throws {
    guard !items.isEmpty else { return }
    let now = Date().timeIntervalSince1970
    try await database.writer.write { db in
      let statement = try db.cachedStatement(sql: """
        INSERT INTO assetText (assetId, text, terms, revision, side, readAt)
        SELECT :id, :text, :terms, :revision, :side, :readAt WHERE EXISTS (SELECT 1 FROM asset WHERE id = :id AND deleted = 0)
        ON CONFLICT(assetId) DO UPDATE SET text = excluded.text, terms = excluded.terms, revision = excluded.revision,
          side = excluded.side, readAt = excluded.readAt
        """)
      for item in items {
        try statement.execute(arguments: [
          "id": item.id, "text": item.text, "terms": TextTerms.terms(item.text).joined(separator: " "),
          "revision": item.revision, "side": item.side, "readAt": now,
        ])
      }
    }
  }

  public func text(assetId: String) async throws -> TextRecord? {
    try await database.writer.read { db in
      try Row.fetchOne(db, sql: "SELECT assetId, text, terms, revision, side, readAt FROM assetText WHERE assetId = ?",
                       arguments: [assetId]).map {
        TextRecord(assetId: $0[0], text: $0[1], terms: $0[2], revision: $0[3], side: $0[4], readAt: $0[5])
      }
    }
  }

  private static func candidateSQL(_ select: String) -> String {
    """
    SELECT \(select) FROM asset INDEXED BY asset_textGated WHERE \(TextGate.candidateWhere)
      AND NOT EXISTS (SELECT 1 FROM assetText t WHERE t.assetId = asset.id AND t.revision = :revision
                      AND (t.side IS NOT NULL OR :retryUnread = 0))
    """
  }

  /// Live, analysed images the gate takes (`TextGate`) whose words haven't been read at `revision`, newest first (ties
  /// by id), at most `limit`. With `retryUnread`, images that couldn't be loaded last time (`side` nil) count again:
  /// for a pass that may download from iCloud.
  public func textCandidateIds(revision: String, retryUnread: Bool, limit: Int) async throws -> [String] {
    try await database.writer.read { db in
      try String.fetchAll(db, sql: Self.candidateSQL("id") + " ORDER BY created DESC, id LIMIT :limit",
                          arguments: ["revision": revision, "retryUnread": retryUnread, "limit": max(0, limit)])
    }
  }

  /// `COUNT(*)` of what `textCandidateIds` would return without a limit.
  public func textCandidateCount(revision: String, retryUnread: Bool) async throws -> Int {
    try await database.writer.read { db in
      try Int.fetchOne(db, sql: Self.candidateSQL("COUNT(*)"),
                       arguments: ["revision": revision, "retryUnread": retryUnread]) ?? 0
    }
  }

  /// Asset id → share (0…1) of `terms` found in that asset's words, for live assets with at least one term found.
  ///
  /// Terms are normalised like indexed text (`TextTerms`; typed search already passes `SearchTerms.terms`) and counted
  /// once. A term matches whole words, Porter-stemmed ("receipt" finds "receipts"). A term of three or more characters
  /// that no live image has as a whole word matches as the start of a word instead ("grok" finds "Grokipedia"), as
  /// DigUp does; a term found whole stays whole, so "cat" doesn't bring in "category". Each term keeps its best
  /// `keywordLimitPerTerm` matches and at most `keywordMaxTerms` terms are used (see there).
  public func keywordCoverage(terms: [String]) async throws -> [String: Double] {
    try await keywordCoverage(terms: terms, limitPerTerm: Self.keywordLimitPerTerm)
  }

  func keywordCoverage(terms: [String], limitPerTerm: Int) async throws -> [String: Double] {
    var seen = Set<String>()
    let words = terms.compactMap { term -> String? in
      let word = TextTerms.terms(term).joined(separator: " ")  // a term with a separator becomes a phrase
      return word.isEmpty || !seen.insert(word).inserted ? nil : word
    }.prefix(Self.keywordMaxTerms)
    guard !words.isEmpty else { return [:] }
    return try await database.writer.read { db in
      let matchSQL = """
        SELECT t.assetId FROM assetTextFts JOIN assetText t ON t.id = assetTextFts.rowid
        JOIN asset a ON a.id = t.assetId
        WHERE assetTextFts MATCH ? AND a.deleted = 0
        """
      var found: [String: Int] = [:]
      for word in words {
        var pattern = "\"\(word)\""  // only letters, digits and spaces: nothing to escape
        if !word.contains(" "), word.count >= 3,
           try String.fetchOne(db, sql: matchSQL + " LIMIT 1", arguments: [pattern]) == nil {
          pattern += "*"
        }
        let ids = try String.fetchAll(db, sql: matchSQL + " ORDER BY assetTextFts.rank LIMIT ?",
                                      arguments: [pattern, max(0, limitPerTerm)])
        for id in Set(ids) { found[id, default: 0] += 1 }
      }
      return found.mapValues { Double($0) / Double(words.count) }
    }
  }
}
