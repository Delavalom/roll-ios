import Foundation
import Testing
@testable import Squish

struct WorkspaceTests {
  @Test func sweepRemovesOnlyStaleEntries() throws {
    let root = try Fixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let ws = SquishWorkspace(root: root)
    let old = root.appendingPathComponent("old"), fresh = root.appendingPathComponent("fresh")
    for url in [old, fresh] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3601)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: fresh.path)
    ws.sweepStale(olderThan: 3600, now: now)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
  }

  @Test func itemDirectoriesAreCreatedUnderTheRoot() throws {
    let root = try Fixtures.tempDir().appendingPathComponent("nested")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let dir = try SquishWorkspace(root: root).makeItemDirectory()
    #expect(dir.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: dir.path))
  }

  @Test func requiredSpaceIsTwiceTheSourcePlusHalfAGigabyte() {
    #expect(SquishDiskSpace.required(forSourceBytes: 0) == 500_000_000)
    #expect(SquishDiskSpace.required(forSourceBytes: 1_000_000_000) == 2_500_000_000)
  }

  @Test func checkThrowsInsufficientSpaceWithTheNumbers() {
    let space = SquishDiskSpace(available: { 1_000_000_000 })
    #expect(throws: Never.self) { try space.check(sourceBytes: 200_000_000) }  // needs 900 MB
    #expect(throws: ReplaceError.insufficientSpace(required: 2_500_000_000, available: 1_000_000_000)) {
      try space.check(sourceBytes: 1_000_000_000)
    }
  }
}
