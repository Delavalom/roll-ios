import Foundation
import Testing
@testable import ModelInstall

/// The model moves into the App Group container once, and stays where it is when there's no group or the move fails.
struct ModelLocationTests {
  private static func temp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ModelLocation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func installModel(at root: URL) throws {
    let folder = root.appending(path: "rev1")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: folder.appending(path: "model.bin"))
  }

  @Test func withoutAGroupTheModelStaysInApplicationSupport() throws {
    let base = try Self.temp()
    let local = base.appending(path: "Support/RollModel")
    #expect(ModelLocation.resolve(local: local, sharedSupport: nil) == local)
  }

  @Test func theFirstLaunchWithTheGroupMovesTheModelThere() throws {
    let base = try Self.temp()
    let local = base.appending(path: "Support/RollModel")
    try Self.installModel(at: local)
    let group = base.appending(path: "Group/Library/Application Support")
    let root = ModelLocation.resolve(local: local, sharedSupport: group)
    #expect(root == group.appending(path: "RollModel"))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "rev1/model.bin").path))
    #expect(!FileManager.default.fileExists(atPath: local.path), "moved, not copied")
    #expect(ModelLocation.resolve(local: local, sharedSupport: group) == root, "later launches use it as is")
  }

  @Test func aFreshInstallStartsInTheGroup() throws {
    let base = try Self.temp()
    let group = base.appending(path: "Group/Library/Application Support")
    let root = ModelLocation.resolve(local: base.appending(path: "Support/RollModel"), sharedSupport: group)
    #expect(root == group.appending(path: "RollModel"))
  }

  @Test func whenBothExistTheGroupCopyWinsAndTheOtherIsRemoved() throws {
    let base = try Self.temp()
    let local = base.appending(path: "Support/RollModel")
    let group = base.appending(path: "Group/Library/Application Support")
    try Self.installModel(at: local)
    try Self.installModel(at: group.appending(path: "RollModel"))
    #expect(ModelLocation.resolve(local: local, sharedSupport: group) == group.appending(path: "RollModel"))
    #expect(!FileManager.default.fileExists(atPath: local.path))
  }

  @Test func aFailedMoveKeepsTheOldFolder() throws {
    let base = try Self.temp()
    let local = base.appending(path: "Support/RollModel")
    try Self.installModel(at: local)
    // The group's support path is a file, so the folder can't be created there.
    let blocker = base.appending(path: "Group")
    try Data().write(to: blocker)
    let root = ModelLocation.resolve(local: local, sharedSupport: blocker.appending(path: "Library/Application Support"))
    #expect(root == local)
    #expect(FileManager.default.fileExists(atPath: local.appending(path: "rev1/model.bin").path))
  }
}
