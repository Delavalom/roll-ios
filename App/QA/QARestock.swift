#if DEBUG
import Commit
import Foundation
import Library
import Overview
import Photos
import Store
import os

/// DEBUG device QA (`-QAAlbum <title> -QARestock`, docs/qa/device-2026-10-23.md): imports the files that
/// `scripts/qa_restock.sh` copied into `Documents/qa-restock/` as new assets in the QA album, so the destructive tests
/// always have originals stored on the iPhone to squish.
///
/// The album is filled to `QARestockRoom.limit` (32), leaving room for the copies the pass saves: first, as few items as
/// needed whose original is only in iCloud are taken out of the album (never deleted; an open squish's original or copy
/// always stays), through the QA gate. With nothing staged it still makes room when the album is over the limit (a
/// failed pass can leave it at 41). If that can't make enough room, nothing changes. Each file is then imported with its original file name and added to
/// the album in one change, after the album is looked up again; imported files are removed from Documents. Every step
/// writes a `qa_restock` event with counts only (no identifiers or file names).
enum QARestock {
  static let directory = URL.documentsDirectory.appending(path: "qa-restock", directoryHint: .isDirectory)
  static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
  static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

  struct Summary: Sendable, Equatable {
    enum Outcome: String, Sendable { case done, partial, nothingToImport = "nothing to import", refused }
    var outcome = Outcome.done
    var files = 0
    var albumBefore = 0
    var removed = 0
    var imported = 0
    var failed = 0
    var albumAfter = 0
    /// Fixed text (no names): why the run stopped.
    var refusal: String?

    /// What the badge's `qa.restock` element says (the UI test reads it).
    var label: String {
      var text = "QA restock: \(outcome.rawValue) · imported \(imported) of \(files) · removed \(removed) · album \(albumAfter) items"
      if failed > 0 { text += " · \(failed) failed" }
      if let refusal { text += " · \(refusal)" }
      return text
    }
  }

  /// The files waiting in `Documents/qa-restock/`, by name.
  static func pendingFiles() -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: [.skipsHiddenFiles])) ?? []
    return urls.filter { url in
      let ext = url.pathExtension.lowercased()
      return (videoExtensions.contains(ext) || photoExtensions.contains(ext))
        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  static func run(title: String, runtime: QARuntime, repositories: Repositories) async -> Summary {
    let log = runtime.log
    let files = pendingFiles()
    var summary = Summary(files: files.count)
    let videos = files.filter { videoExtensions.contains($0.pathExtension.lowercased()) }.count
    func finish(_ outcome: Summary.Outcome, refusal: String? = nil) -> Summary {
      summary.outcome = outcome
      summary.refusal = refusal
      if case .found(let ids) = PhotoKitQAAlbum.lookup(title: title) { summary.albumAfter = ids.count }
      log.write("qa_restock", [
        "step": .string("done"), "outcome": .string(outcome.rawValue), "files": .int(summary.files),
        "albumBefore": .int(summary.albumBefore), "removed": .int(summary.removed), "imported": .int(summary.imported),
        "failed": .int(summary.failed), "albumAfter": .int(summary.albumAfter),
      ].merging(refusal.map { ["refusal": .string($0)] } ?? [:]) { a, _ in a })
      return summary
    }

    let members: Set<String>
    switch PhotoKitQAAlbum.lookup(title: title) {
    case .missing: return finish(.refused, refusal: "no QA album")
    case .ambiguous: return finish(.refused, refusal: "more than one QA album")
    case .found(let ids): members = ids
    }
    guard !files.isEmpty || members.count > QARestockRoom.limit else { return finish(.nothingToImport) }
    summary.albumBefore = members.count
    log.write("qa_restock", ["step": .string("start"), "files": .int(files.count), "videos": .int(videos),
                             "photos": .int(files.count - videos), "albumBefore": .int(members.count)])

    // Make room: oldest first, only iCloud-only originals, never an open squish's original or copy.
    let open: Set<String>, copies: Set<String>
    do {
      open = try await repositories.openJournalAssetIDs()
      copies = try await repositories.journaledCopyIDs()
    } catch {
      return finish(.refused, refusal: "can't read the squish journal")  // can't tell which items must stay
    }
    let candidates = orderedMembers(title: title).filter(members.contains)
    var checked = 0
    let plan = await QARestockRoom.plan(albumCount: members.count, incoming: files.count, candidates: candidates,
                                        protected: open.union(copies)) { id in
      checked += 1
      return await Deadline.answer(within: LocalityScanner.defaultTimeout) { await PhotoKitLocality.isLocal(id: id) }
        .flatMap { $0 }.map { !$0 }
    }
    switch plan {
    case .refused(let needed, let found):
      log.write("qa_restock", ["step": .string("room"), "needed": .int(needed), "found": .int(found),
                               "checked": .int(checked), "allowed": .bool(false)])
      return finish(.refused, refusal: "needs room for \(needed), found \(found) iCloud-only items")
    case .remove(let ids):
      log.write("qa_restock", ["step": .string("room"), "needed": .int(ids.count), "found": .int(ids.count),
                               "checked": .int(checked), "allowed": .bool(true)])
      if !ids.isEmpty {
        do {
          try await runtime.gate.check(ids, for: .removeFromQAAlbum)
          try await removeFromAlbum(title: title, ids)
          summary.removed = ids.count
        } catch let violation as QAScopeViolation {
          return finish(.refused, refusal: violation.description)
        } catch {
          return finish(.refused, refusal: "remove failed (\((error as NSError).domain) \((error as NSError).code))")
        }
      }
    }

    // Import, re-reading the album before each file so it never goes over the limit.
    let start = Date()
    var created: [String] = []
    for file in files {
      guard case .found(let ids) = PhotoKitQAAlbum.lookup(title: title) else {
        return finish(.refused, refusal: "the QA album changed during the import")
      }
      guard ids.count < QARestockRoom.limit else {
        return finish(summary.imported > 0 ? .partial : .refused, refusal: "the QA album is full")
      }
      do {
        created.append(try await importFile(file, title: title))
        summary.imported += 1
        try? FileManager.default.removeItem(at: file)
      } catch {
        summary.failed += 1
        log.write("qa_restock", ["step": .string("import"), "ok": .bool(false),
                                 "error": .string("\((error as NSError).domain) \((error as NSError).code)")])
      }
    }

    // Did Photos take the files' own dates and locations (for the metadata checks after a squish)?
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    var withLocation = 0, datedFromFile = 0
    PHAsset.fetchAssets(withLocalIdentifiers: created, options: options).enumerateObjects { asset, _, _ in
      if asset.location != nil { withLocation += 1 }
      if let date = asset.creationDate, date < start.addingTimeInterval(-86_400) { datedFromFile += 1 }
    }
    log.write("qa_restock", ["step": .string("imported"), "imported": .int(created.count),
                             "withLocation": .int(withLocation), "datedFromFile": .int(datedFromFile)])
    return finish(summary.failed == 0 ? .done : .partial)
  }

  // MARK: - PhotoKit

  /// The unique regular album with this title (the caller has just checked it with `PhotoKitQAAlbum.lookup`).
  private static func album(_ title: String) -> PHAssetCollection? {
    var matches: [PHAssetCollection] = []
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, _ in
      if c.localizedTitle == title { matches.append(c) }
    }
    return matches.count == 1 ? matches[0] : nil
  }

  private static func orderedMembers(title: String) -> [String] {
    guard let album = album(title) else { return [] }
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    var ids: [String] = []
    PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
    return ids
  }

  enum RestockError: Error { case noAlbum, noPlaceholder }

  /// Takes the assets out of the album only (`removeAssets`); they stay in the library.
  private static func removeFromAlbum(title: String, _ ids: [String]) async throws {
    guard let albumID = album(title)?.localIdentifier else { throw RestockError.noAlbum }
    try await PHPhotoLibrary.shared().performChanges {
      guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
            let request = PHAssetCollectionChangeRequest(for: album) else { return }
      let options = PHFetchOptions()
      options.includeHiddenAssets = true
      request.removeAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options))
    }
  }

  /// One new asset from the file, with its original file name, added to the album in the same change.
  private static func importFile(_ url: URL, title: String) async throws -> String {
    guard let albumID = album(title)?.localIdentifier else { throw RestockError.noAlbum }
    let isVideo = videoExtensions.contains(url.pathExtension.lowercased())
    let placeholder = OSAllocatedUnfairLock<String?>(initialState: nil)
    try await PHPhotoLibrary.shared().performChanges {
      // The album first: without it nothing is created (an import outside the album would escape the QA scope).
      guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
            let request = PHAssetCollectionChangeRequest(for: album) else { return }
      let creation = PHAssetCreationRequest.forAsset()
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = url.lastPathComponent
      creation.addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
      guard let created = creation.placeholderForCreatedAsset else { return }
      request.addAssets([created] as NSArray)
      placeholder.withLock { $0 = created.localIdentifier }
    }
    guard let id = placeholder.withLock({ $0 }) else { throw RestockError.noPlaceholder }
    return id
  }
}
#endif
