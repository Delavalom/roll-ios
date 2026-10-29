#if DEBUG
import Entitlements
import Foundation
import Store
#if canImport(Photos) && os(iOS)
import Photos
#endif

// DEBUG-only device QA (`-QAAlbum <title>`, see docs/qa/). Release builds compile none of this file.
//
// In QA mode the app's whole library scope is one user album. The scope is enforced twice: the app's library source only
// lists the album's assets (so the Store, Squish, Duplicates, swipefiles and the commit planner never see anything else),
// and this gate re-reads the album right before every destructive call and refuses any id that isn't in it.

/// What a destructive call is about to do, for the gate's error message.
public enum QAOperation: String, Sendable, Equatable {
  case delete = "delete"
  case addToAlbum = "add to an album"
  case squish = "squish"
  case deleteSquishedOriginal = "delete a squished original"
  case discardCopy = "remove a squish copy"
  /// `-QARestock`: takes iCloud-only items out of the QA album (never deletes them) to make room for local ones.
  case removeFromQAAlbum = "remove from the QA album"
}

/// The QA album as the library has it right now.
public enum QAAlbumLookup: Sendable, Equatable {
  case missing
  /// More than one regular user album has this title, so "the" QA album is unclear.
  case ambiguous(count: Int)
  /// Image and video ids in the album (hidden ones included).
  case found(Set<String>)
}

/// Why the gate refused. Nothing was changed.
public enum QAScopeViolation: Error, Equatable, LocalizedError, CustomStringConvertible {
  case albumMissing(title: String)
  case albumAmbiguous(title: String, count: Int)
  case albumTooLarge(title: String, count: Int, limit: Int)
  case notInAlbum(title: String, operation: QAOperation, refused: Int, of: Int)
  /// A read-only QA run (`-QAMetrics` without `-QAAlbum`): every change is refused.
  case readOnlyRun(operation: QAOperation)

  public var description: String {
    switch self {
    case .readOnlyRun(let operation):
      "QA scope: this is a read-only QA run, so Roll refused to \(operation.rawValue)."
    case .albumMissing(let title):
      "QA scope: there is no album named \"\(title)\", so nothing may be changed."
    case .albumAmbiguous(let title, let count):
      "QA scope: \(count) albums are named \"\(title)\"; rename all but one before running destructive QA."
    case .albumTooLarge(let title, let count, let limit):
      "QA scope: \"\(title)\" holds \(count) items, more than the \(limit) QA allows; it may not be a throwaway album."
    case .notInAlbum(let title, let operation, let refused, let of):
      "QA scope: refused to \(operation.rawValue): \(refused) of \(of) items are not in \"\(title)\"."
    }
  }

  public var errorDescription: String? { description }
}

/// Checks ids against the QA scope right before a destructive call.
public protocol QAScopeGate: Sendable {
  /// Throws `QAScopeViolation` unless every id is in scope. The scope is re-read on every call, never cached.
  func check(_ ids: [String], for operation: QAOperation) async throws
}

/// The `-QAAlbum` gate: every id must be in the album titled `title`, looked up again on each check.
public struct QAAlbumGate: QAScopeGate {
  /// Destructive QA starts with at most 40 throwaway items (the UI tests refuse more). Each squish adds its copy to the
  /// album before the original goes, so the album may briefly hold up to twice that.
  public static let startLimit = 40
  public static let defaultLimit = 2 * startLimit

  public let title: String
  public let limit: Int
  private let lookup: @Sendable (String) async -> QAAlbumLookup

  public init(title: String, limit: Int = QAAlbumGate.defaultLimit,
              lookup: @escaping @Sendable (String) async -> QAAlbumLookup) {
    self.title = title; self.limit = limit; self.lookup = lookup
  }

  public func check(_ ids: [String], for operation: QAOperation) async throws {
    guard !ids.isEmpty else { return }
    switch await lookup(title) {
    case .missing:
      throw QAScopeViolation.albumMissing(title: title)
    case .ambiguous(let count):
      throw QAScopeViolation.albumAmbiguous(title: title, count: count)
    case .found(let members):
      if members.count > limit { throw QAScopeViolation.albumTooLarge(title: title, count: members.count, limit: limit) }
      let unique = Set(ids)
      let refused = unique.subtracting(members).count
      if refused > 0 {
        throw QAScopeViolation.notInAlbum(title: title, operation: operation, refused: refused, of: unique.count)
      }
    }
  }
}

/// The gate of a read-only QA run: refuses every change.
public struct QAReadOnlyGate: QAScopeGate {
  public init() {}
  public func check(_ ids: [String], for operation: QAOperation) async throws {
    guard !ids.isEmpty else { return }
    throw QAScopeViolation.readOnlyRun(operation: operation)
  }
}

/// `-QARestock` (DEBUG): which album items make room for `incoming` local files so the album stays within `limit`.
/// Only items whose original is only in iCloud may go (they can't be squished), never ones in `protected` (an open
/// squish's original or copy), and no more than needed. Removing from the album never deletes an asset.
public enum QARestockRoom {
  /// Places a destructive pass needs above the restocked album: each squish adds its copy before the original goes,
  /// and an interrupted one (D3, D5's decline) keeps both until recovery, while every launch must still see at most
  /// `QAAlbumGate.startLimit` items. A restock to exactly 40 made D3's relaunch refuse 41 (2026-10-24).
  public static let passHeadroom = 8
  /// What a restock fills the album to.
  public static let limit = QAAlbumGate.startLimit - passHeadroom

  public enum Plan: Sendable, Equatable {
    /// Remove these ids from the album (empty: there is room already), then import.
    case remove([String])
    /// Not enough iCloud-only items to make room, or more files than the album may hold: change nothing.
    case refused(needed: Int, found: Int)
  }

  /// How many items must leave the album before `incoming` files fit.
  public static func needed(albumCount: Int, incoming: Int, limit: Int = QARestockRoom.limit) -> Int {
    max(0, albumCount + incoming - limit)
  }

  /// Checks `candidates` in order, only until enough iCloud-only ones are found. `isICloudOnly` answers true (only in
  /// iCloud), false (on the device) or nil (no answer, so it stays).
  public static func plan(albumCount: Int, incoming: Int, candidates: [String], protected: Set<String>,
                          limit: Int = QARestockRoom.limit,
                          isICloudOnly: (String) async -> Bool?) async -> Plan {
    let needed = needed(albumCount: albumCount, incoming: incoming, limit: limit)
    guard incoming <= limit else { return .refused(needed: needed, found: 0) }
    guard needed > 0 else { return .remove([]) }
    var picked: [String] = []
    for id in candidates where !protected.contains(id) {
      if await isICloudOnly(id) == true { picked.append(id) }
      if picked.count == needed { return .remove(picked) }
    }
    return .refused(needed: needed, found: picked.count)
  }
}

/// The committer's library seam with the gate in front of every change.
struct QAGatedCommitLibrary: CommitLibrary {
  let base: any CommitLibrary
  let gate: any QAScopeGate

  func delete(_ ids: [String]) async throws {
    try await gate.check(ids, for: .delete)
    try await base.delete(ids)
  }

  func addToAlbum(named name: String, _ ids: [String]) async throws {
    try await gate.check(ids, for: .addToAlbum)
    try await base.addToAlbum(named: name, ids)
  }
}

#if canImport(Photos) && os(iOS)
extension PhotoKitCommitter {
  /// The production committer with the QA gate in front of every delete and album move. Squishes are gated by the
  /// runner (pass one built with `ReplaceFlowRunner.qaScoped`).
  public convenience init(database: AppDatabase, pro: any ProStatus, squish: (any SquishRunner)?, qaGate: any QAScopeGate) {
    self.init(library: QAGatedCommitLibrary(base: PhotoKitCommitLibrary(), gate: qaGate), database: database, pro: pro,
              squish: squish)
  }
}

/// Reads the QA album from PhotoKit (read-only).
public enum PhotoKitQAAlbum {
  public static func lookup(title: String) -> QAAlbumLookup {
    var matches: [PHAssetCollection] = []
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, _ in
      if c.localizedTitle == title { matches.append(c) }
    }
    guard let album = matches.first else { return .missing }
    if matches.count > 1 { return .ambiguous(count: matches.count) }
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    var ids = Set<String>()
    PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
      if asset.mediaType == .image || asset.mediaType == .video { ids.insert(asset.localIdentifier) }
    }
    return .found(ids)
  }

  /// The gate the app uses in QA mode.
  public static func gate(title: String) -> QAAlbumGate {
    QAAlbumGate(title: title) { lookup(title: $0) }
  }
}
#endif
#endif
