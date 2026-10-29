import Foundation

/// Scratch space for one squish run: each item gets its own directory under `root`, removed when the item is done.
public struct SquishWorkspace: Sendable {
  public let root: URL

  public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("roll-squish")) {
    self.root = root
  }

  public func makeItemDirectory() throws -> URL {
    let dir = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Marks a directory as in use so `sweepStale` leaves a long-running item alone.
  public func touch(_ dir: URL) {
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
  }

  /// Removes leftovers from runs that crashed or were killed (anything not modified for `age` seconds).
  public func sweepStale(olderThan age: TimeInterval = 3600, now: Date = Date()) {
    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    for url in children {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, now.timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
    }
  }
}

/// Free-space gate: re-encoding needs the exported original plus the output on disk at once.
public struct SquishDiskSpace: Sendable {
  public static let safetyMargin: Int64 = 500_000_000

  public static func required(forSourceBytes bytes: Int64) -> Int64 { 2 * bytes + safetyMargin }

  let available: @Sendable () -> Int64

  public init(available: @escaping @Sendable () -> Int64) { self.available = available }

  /// Free space for important usage on the volume holding `url`.
  public init(volumeOf url: URL = FileManager.default.temporaryDirectory) {
    self.init(available: {
      let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      return values?.volumeAvailableCapacityForImportantUsage ?? 0
    })
  }

  /// After the original is on disk: room for the output (about as big as the source in the worst case) plus the margin.
  public func checkRoomForOutput(exportedBytes: Int64) throws {
    let need = exportedBytes + Self.safetyMargin, have = available()
    if have < need { throw ReplaceError.insufficientSpace(required: need, available: have) }
  }

  public func check(sourceBytes: Int64) throws {
    let need = Self.required(forSourceBytes: sourceBytes), have = available()
    if have < need { throw ReplaceError.insufficientSpace(required: need, available: have) }
  }
}
