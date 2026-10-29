import Foundation
import Synchronization
@testable import Squish

/// An in-memory photo library with real per-asset state: fingerprints, albums, modification dates, resources and an
/// access level. `createCopy` and the deletes mutate that state, and the commit guard runs on it exactly as it
/// would on PhotoKit. All state is behind one lock.
final class FakeLibrary: PhotoLibraryGateway, @unchecked Sendable {
  enum Export { case normal, needsDownload, hangUntilCancelled, thumbnail }

  struct Asset {
    var fp: AssetFingerprint
    var facts: AssetFacts
    var filename: String
    /// What a read-back returns (set when the asset is created from a file).
    var stored: CopyReadBack?
    /// Albums the fingerprint doesn't track (shared, smart, read-only).
    var readOnlyAlbumIDs: Set<String> = []
  }

  struct State {
    var access = LibraryAccessLevel.full
    var assets: [String: Asset] = [:]
    var calls: [String] = []
    var nextID = 0
    var export = Export.normal
    var declineDelete = false
    var createError: (any Error)?
    var deleteError: (any Error)?
    /// Creation finds no original (it vanished inside the change block): nothing is created.
    var originalVanishesDuringCreate = false
    /// The original disappears right after the copy is created.
    var originalVanishesAfterCreate = false
    var tamperCopy: (@Sendable (inout Asset) -> Void)?
    var corruptReadBackHash = false
    var onExport: (@Sendable () -> Void)?
    var onCreated: (@Sendable () -> Void)?
    /// Runs at the moment the placeholder id is known, before the copy exists.
    var atPlaceholder: (@Sendable (String) -> Void)?
  }

  private let state = Mutex(State())
  let source: URL
  let sourceWidth: Int, sourceHeight: Int

  init(source: URL, width: Int = 1600, height: Int = 1200) {
    self.source = source; sourceWidth = width; sourceHeight = height
  }

  // MARK: Test controls

  func configure(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
  var calls: [String] { state.withLock { $0.calls } }
  func has(_ id: String) -> Bool { state.withLock { $0.assets[id] != nil } }
  func asset(_ id: String) -> Asset? { state.withLock { $0.assets[id] } }
  func copyIDs() -> [String] { state.withLock { $0.assets.keys.filter { $0.hasPrefix("new-") }.sorted() } }

  @discardableResult
  func addPhoto(_ id: String, albums: Set<String> = ["A1"], favorite: Bool = true, uti: String = "public.jpeg") -> String {
    let fp = AssetFingerprint(isVideo: false, duration: 0, pixelWidth: sourceWidth, pixelHeight: sourceHeight,
                              creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                              modificationDate: Date(timeIntervalSince1970: 1_700_000_100), isFavorite: favorite, isHidden: false,
                              latitude: 37.77, longitude: -122.42, albumIDs: albums)
    let facts = AssetFacts(mediaType: 1, subtypes: 0, resources: [.photo], burstIdentifier: nil, isUserLibrary: true, uti: uti)
    state.withLock { $0.assets[id] = Asset(fp: fp, facts: facts, filename: "IMG_\(id).JPG") }
    return id
  }

  @discardableResult
  func addVideo(_ id: String, duration: Double = 2) -> String {
    let fp = AssetFingerprint(isVideo: true, duration: duration, pixelWidth: sourceWidth, pixelHeight: sourceHeight,
                              creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                              modificationDate: Date(timeIntervalSince1970: 1_700_000_100), isFavorite: false, isHidden: false,
                              latitude: nil, longitude: nil, albumIDs: ["A1"])
    let facts = AssetFacts(mediaType: 2, subtypes: 0, resources: [.video], burstIdentifier: nil, isUserLibrary: true,
                           uti: "com.apple.quicktime-movie")
    state.withLock { $0.assets[id] = Asset(fp: fp, facts: facts, filename: "IMG_\(id).MOV") }
    return id
  }

  func edit(_ id: String) {
    state.withLock {
      $0.assets[id]?.facts.resources.append(.edit)
      $0.assets[id]?.fp.modificationDate = Date()
    }
  }
  func addToAlbum(_ id: String, _ album: String) { state.withLock { _ = $0.assets[id]?.fp.albumIDs.insert(album) } }
  func setFavorite(_ id: String, _ value: Bool) { state.withLock { $0.assets[id]?.fp.isFavorite = value } }
  func remove(_ id: String) { state.withLock { $0.assets[id] = nil } }

  // MARK: Gateway

  var accessLevel: LibraryAccessLevel { state.withLock { $0.access } }

  private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

  func inspect(_ assetID: String) async throws -> LibraryAsset {
    record("inspect:\(assetID)")
    guard let a = state.withLock({ $0.assets[assetID] }) else { throw ReplaceError.assetNotFound }
    return LibraryAsset(facts: a.facts, originalFilename: a.filename, pixelWidth: a.fp.pixelWidth, pixelHeight: a.fp.pixelHeight)
  }

  func exportOriginal(_ assetID: String, to directory: URL, allowNetwork: Bool,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    record("export:\(assetID)")
    let (mode, hook) = state.withLock { ($0.export, $0.onExport) }
    hook?()
    let dest = directory.appendingPathComponent("original-\(assetID)." + source.pathExtension)
    switch mode {
    case .needsDownload: throw ReplaceError.needsDownload
    case .hangUntilCancelled: try await Task.sleep(for: .seconds(60))
    case .thumbnail:
      try Fixtures.makeJPEG(at: dest, width: 160, height: 120)
      return dest
    case .normal: break
    }
    try FileManager.default.copyItem(at: source, to: dest)
    progress(1)
    return dest
  }

  func createCopy(of assetID: String, from file: URL, filename: String,
                  onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> String {
    record("create:\(assetID)")
    if let e = state.withLock({ $0.createError }) { throw ReplaceError.createFailed(e) }
    // The change block re-reads the original; if it is gone, nothing is created.
    guard state.withLock({ $0.assets[assetID] != nil && !$0.originalVanishesDuringCreate }) else {
      state.withLock { $0.assets[assetID] = nil }
      throw ReplaceError.createFailed(ReplaceError.assetNotFound)
    }
    let id = state.withLock { s -> String in s.nextID += 1; return "new-\(s.nextID)" }
    state.withLock { $0.atPlaceholder }?(id)
    onPlaceholder(id)

    let digest = try FileDigest.of(file)
    let ext = file.pathExtension.lowercased()
    let isVideo = ext == "mov" || ext == "mp4"
    try state.withLock { s in
      guard let original = s.assets[assetID] else { throw ReplaceError.assetNotFound }
      var fp = original.fp
      fp.modificationDate = Date()
      fp.albumIDs = original.fp.albumIDs  // writable albums only; read-only ones are not copied
      let uti = isVideo ? (ext == "mp4" ? "public.mpeg-4" : "com.apple.quicktime-movie") : "public.heic"
      var copy = Asset(
        fp: fp,
        facts: AssetFacts(mediaType: isVideo ? 2 : 1, subtypes: 0, resources: [isVideo ? .video : .photo], burstIdentifier: nil,
                          isUserLibrary: true, uti: uti),
        filename: filename,
        stored: CopyReadBack(resources: [isVideo ? .video : .photo], uti: uti, bytes: digest.bytes,
                             sha256: s.corruptReadBackHash ? "deadbeef" : digest.sha256))
      s.tamperCopy?(&copy)
      s.assets[id] = copy
      if s.originalVanishesAfterCreate { s.assets[assetID] = nil }
    }
    state.withLock { $0.onCreated }?()
    return id
  }

  func fingerprint(_ assetID: String) async -> AssetFingerprint? {
    record("fingerprint:\(assetID)")
    return state.withLock { $0.assets[assetID]?.fp }
  }

  func readBack(_ assetID: String) async throws -> CopyReadBack {
    record("readBack:\(assetID)")
    guard let stored = state.withLock({ $0.assets[assetID]?.stored }) else { throw ReplaceError.assetNotFound }
    return stored
  }

  func deleteGuarded(_ items: [Prepared]) async throws -> [GuardedOutcome] {
    if accessLevel != .full { throw ReplaceError.needsFullAccess }
    return try state.withLock { s in
      // Same shape as the PhotoKit change block: decide from the current state, then delete what passed.
      var outcomes: [GuardedOutcome] = [], doomed: [String] = []
      for p in items {
        func snap(_ id: String) -> LibrarySnapshot? { s.assets[id].map { LibrarySnapshot(fingerprint: $0.fp, facts: $0.facts) } }
        let reason = CommitGuard.decide(p, original: snap(p.assetID), copy: snap(p.newAssetID))
        outcomes.append(GuardedOutcome(prepared: p, skip: reason))
        if reason == nil { doomed.append(p.assetID) }
      }
      s.calls.append("deleteGuarded:" + items.map(\.assetID).joined(separator: ","))
      if s.declineDelete { throw ReplaceError.userDeclinedDelete }
      if let e = s.deleteError { throw ReplaceError.deleteFailed(e) }
      for id in doomed { s.assets[id] = nil }
      s.calls.append("delete:" + doomed.joined(separator: ","))
      return outcomes
    }
  }

  func delete(_ copyIDs: [String]) async throws {
    if accessLevel != .full { throw ReplaceError.needsFullAccess }
    try state.withLock { s in
      s.calls.append("discard:" + copyIDs.joined(separator: ","))
      if s.declineDelete { throw ReplaceError.userDeclinedDelete }
      if let e = s.deleteError { throw ReplaceError.deleteFailed(e) }
      for id in copyIDs { s.assets[id] = nil }
    }
  }
}
