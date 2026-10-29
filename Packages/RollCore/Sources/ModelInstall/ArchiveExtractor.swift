import AppleArchive
import Foundation
import System

/// Unpacks the downloaded archive into a folder. `AppleArchiveExtractor` in the app and in tests.
public protocol ArchiveExtractor: Sendable {
  /// Extracts `archive` into the existing, empty `directory`.
  func extract(_ archive: URL, into directory: URL) throws
}

/// Apple Archive (`.aar`, any compression the framework reads, LZFSE for the model) through the AppleArchive
/// framework. Only regular files and directories with plain relative paths are extracted; a symlink, device, FIFO or
/// socket, an absolute path, a "." or ".." component, or an entry whose type can't be read fails the whole extraction
/// (the archive is already checksum-verified, so this guards against a bad publish, not an attacker). Hard links are
/// not rejected: Apple Archive stores them as regular files of one cluster (`HLC`), linked only to another entry of
/// the same archive, so they stay inside `directory`. The volume filling up throws `.insufficientSpace` (with zero
/// sizes; the installer fills them in).
public struct AppleArchiveExtractor: ArchiveExtractor {
  public init() {}

  public func extract(_ archive: URL, into directory: URL) throws {
    guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [],
                                                  permissions: FilePermissions(rawValue: 0o644)) else {
      throw ModelInstallError.badArchive("can't open \(archive.lastPathComponent)")
    }
    defer { try? file.close() }
    guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else {
      throw ModelInstallError.badArchive("not an Apple Archive")
    }
    defer { try? decompressed.close() }
    guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else {
      throw ModelInstallError.badArchive("not an Apple Archive")
    }
    defer { try? decoder.close() }
    let rejected = RejectedEntry()
    let filter: ArchiveHeader.EntryFilter = { message, path, data in
      guard message == .extractBegin else { return .ok }
      if !Self.isPlain(path.string) || !Self.isFileOrDirectory(data) {
        rejected.path = path.string
        return .cancel
      }
      return .ok
    }
    guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(directory.path), selectUsing: filter,
                                                      flags: [.ignoreOperationNotPermitted]) else {
      throw ModelInstallError.badArchive("can't extract into \(directory.lastPathComponent)")
    }
    errno = 0  // so a leftover value isn't read as this extraction's
    do {
      _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
      try extractor.close()
    } catch {
      let code = errno
      try? extractor.close()
      if let bad = rejected.path { throw ModelInstallError.badArchive("unexpected entry \(bad)") }
      let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
      if Self.outOfSpace(errno: code, freeBytes: free.map(Int64.init)) {
        throw ModelInstallError.insufficientSpace(required: 0, available: 0)
      }
      throw ModelInstallError.badArchive(String(describing: error))
    }
    if let bad = rejected.path { throw ModelInstallError.badArchive("unexpected entry \(bad)") }
  }

  /// A relative path of plain components ("" is the archive's root directory entry).
  static func isPlain(_ path: String) -> Bool {
    if path.isEmpty || path == "." { return true }
    guard !path.hasPrefix("/") else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !["", ".", ".."].contains($0) }
  }

  /// Fails closed: no header or no entry type is a rejection.
  static func isFileOrDirectory(_ data: ArchiveHeader.EntryFilterData?) -> Bool {
    guard let data, case .header(let header) = data, let type = header.entryType else { return false }
    return type == .regularFile || type == .directory
  }

  /// Below this much free space after a failed extraction, the failure is taken for a full volume: the framework's
  /// error doesn't say why a write failed, and errno is only set when the write ran on this thread.
  static let fullVolumeMargin: Int64 = 64 << 20

  static func outOfSpace(errno code: Int32, freeBytes: Int64?) -> Bool {
    code == ENOSPC || code == EDQUOT || freeBytes.map { $0 < fullVolumeMargin } ?? false
  }
}

/// Written by the filter (the framework calls it synchronously during `process`), read after it returns.
private final class RejectedEntry: @unchecked Sendable {
  var path: String?
}
