import AppleArchive
import Foundation
import System
import Testing
@testable import ModelInstall

struct ExtractorTests {
  @Test func extractsAnLZFSEArchiveWithItsFolders() throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let src = try Fixture.modelFolder(in: dir.url, payload: "the weights")
    let archive = dir.url.appending(path: "m.aar")
    try Fixture.archive(src, to: archive)
    let out = dir.url.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    try AppleArchiveExtractor().extract(archive, into: out)

    let weights = out.appending(path: "EmbeddingGemma2.mlpackage/Data/weights/weight.bin")
    #expect(try String(contentsOf: weights, encoding: .utf8) == "the weights")
    for required in ModelManifest.requiredFiles {
      #expect(FileManager.default.fileExists(atPath: out.appending(path: required).path))
    }
  }

  @Test func refusesSymbolicLinks() throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let src = try Fixture.modelFolder(in: dir.url)
    try FileManager.default.createSymbolicLink(at: src.appending(path: "escape"), withDestinationURL: URL(filePath: "/etc"))
    let archive = dir.url.appending(path: "m.aar")
    try Fixture.archive(src, to: archive)
    let out = dir.url.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    #expect(throws: ModelInstallError.self) { try AppleArchiveExtractor().extract(archive, into: out) }
    #expect(!FileManager.default.fileExists(atPath: out.appending(path: "escape").path))
  }

  /// Hand-built archives (the AppleArchive encoder writes any path it is given): a file at an absolute path, a file
  /// above the folder, and a symlink, each after a plain file. Each fails the extraction and nothing lands where the
  /// entry points.
  @Test(arguments: [EvilEntry.absolutePath, .parentDirectory, .symlink])
  func refusesAnEntryThatEscapesOrIsALink(_ kind: EvilEntry) throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let out = dir.url.appending(path: "out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let escaped = dir.url.appending(path: "escaped.txt")
    let archive = dir.url.appending(path: "evil.aar")
    try kind.write(to: archive, escapingTo: escaped)

    let error = #expect(throws: ModelInstallError.self) { try AppleArchiveExtractor().extract(archive, into: out) }
    // The framework refuses absolute and ".." paths itself (an I/O error); the filter is the second line for those
    // and the only one for the symlink.
    guard case .badArchive(let why)? = error else {
      Issue.record("expected badArchive, got \(String(describing: error))")
      return
    }
    if kind == .symlink { #expect(why == "unexpected entry escape") }
    #expect(!FileManager.default.fileExists(atPath: escaped.path))
    #expect(!FileManager.default.fileExists(atPath: out.appending(path: "escape").path))
    // The plain file before it was read: the archive itself is well formed.
    #expect(FileManager.default.fileExists(atPath: out.appending(path: "ok.txt").path))
  }

  @Test func anEntryWithoutAReadableTypeIsRefused() {
    #expect(!AppleArchiveExtractor.isFileOrDirectory(nil))
    #expect(!AppleArchiveExtractor.isFileOrDirectory(.header(ArchiveHeader())))  // no TYP field
  }

  @Test func aFullVolumeIsNotABadArchive() {
    #expect(AppleArchiveExtractor.outOfSpace(errno: ENOSPC, freeBytes: nil))
    #expect(AppleArchiveExtractor.outOfSpace(errno: 0, freeBytes: 1 << 20))
    #expect(!AppleArchiveExtractor.outOfSpace(errno: 0, freeBytes: 1 << 40))
    #expect(!AppleArchiveExtractor.outOfSpace(errno: EIO, freeBytes: nil))
  }

  @Test func refusesSomethingThatIsNotAnArchive() throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let bogus = dir.url.appending(path: "m.aar")
    try Data("not an archive".utf8).write(to: bogus)
    #expect(throws: ModelInstallError.self) { try AppleArchiveExtractor().extract(bogus, into: dir.url) }
  }

  @Test(arguments: [("", true), ("a/b.bin", true), ("/etc/passwd", false), ("../x", false), ("a/../../x", false),
                    ("a//b", false)])
  func acceptsOnlyPlainRelativePaths(_ path: String, _ plain: Bool) {
    #expect(AppleArchiveExtractor.isPlain(path) == plain)
  }
}

/// One hostile entry after a plain file, in an uncompressed Apple Archive.
enum EvilEntry: CaseIterable, Sendable {
  case absolutePath, parentDirectory, symlink

  func write(to out: URL, escapingTo escaped: URL) throws {
    let file = try #require(ArchiveByteStream.fileStream(path: FilePath(out.path), mode: .writeOnly,
                                                         options: [.create, .truncate],
                                                         permissions: FilePermissions(rawValue: 0o644)))
    let encoder = try #require(ArchiveStream.encodeStream(writingTo: file))
    try Self.writeFile(encoder, path: "ok.txt", contents: "fine")
    switch self {
    case .absolutePath: try Self.writeFile(encoder, path: escaped.path, contents: "escaped")
    case .parentDirectory: try Self.writeFile(encoder, path: "../\(escaped.lastPathComponent)", contents: "escaped")
    case .symlink:
      let header = ArchiveHeader()
      header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(ArchiveHeader.EntryType.link.rawValue)))
      header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: "escape"))
      header.append(.string(key: ArchiveHeader.FieldKey("LNK"), value: escaped.path))
      try encoder.writeHeader(header)
    }
    try encoder.close()
    try file.close()
  }

  private static func writeFile(_ encoder: ArchiveStream, path: String, contents: String) throws {
    let data = Data(contents.utf8)
    let header = ArchiveHeader()
    let type = UInt64(ArchiveHeader.EntryType.regularFile.rawValue)
    header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: type))
    header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: path))
    header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(data.count)))
    try encoder.writeHeader(header)
    try data.withUnsafeBytes { try encoder.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) }
  }
}
