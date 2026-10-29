import Foundation
import GRDB
import Testing
@testable import Store

/// Passing video format probes, kept per asset and keyed by `modified` like squish refusals.
struct VideoProbeTests {
  @Test func aPassHoldsWhileTheAssetIsUnchanged() async throws {
    let repo = Repositories(try AppDatabase.inMemory())
    var a = Fixtures.asset("a", mediaType: 2)
    a.modified = 10
    try await repo.upsertAssets([a, Fixtures.asset("b", mediaType: 2), Fixtures.asset("gone", mediaType: 2)])
    try await repo.recordVideoProbePassed(assetId: "a")
    try await repo.recordVideoProbePassed(assetId: "b")
    try await repo.recordVideoProbePassed(assetId: "gone")
    try await repo.recordVideoProbePassed(assetId: "unknown")
    try await repo.markDeleted(["gone"])
    #expect(try await repo.passedVideoProbes() == ["a", "b"])

    a.modified = 11  // edited since the probe: probe again
    try await repo.upsertAssets([a])
    #expect(try await repo.passedVideoProbes() == ["b"])
  }

  /// What the probe measured (codec, real file size, frame rate) is kept with the pass and survives a relaunch, so the
  /// planner can tell an already compact HEVC video from one worth squishing without probing again.
  @Test func theMeasuredFactsSurviveARelaunch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("roll.sqlite")
    do {
      let repo = Repositories(try AppDatabase.open(at: url))
      var edited = Fixtures.asset("edited", mediaType: 2)
      edited.modified = 1
      try await repo.upsertAssets([Fixtures.asset("hevc", mediaType: 2), Fixtures.asset("plain", mediaType: 2), edited])
      try await repo.recordVideoProbePassed(assetId: "hevc",
                                            facts: VideoProbeFacts(codec: "hvc1", bytes: 6_250_000, fps: 29.97))
      try await repo.recordVideoProbePassed(assetId: "plain")
      try await repo.recordVideoProbePassed(assetId: "edited", facts: VideoProbeFacts(codec: "avc1", bytes: 1, fps: 30))
      edited.modified = 2
      try await repo.upsertAssets([edited])
    }
    let relaunched = Repositories(try AppDatabase.open(at: url))
    #expect(try await relaunched.videoProbeFacts() == [
      "hevc": VideoProbeFacts(codec: "hvc1", bytes: 6_250_000, fps: 29.97),
      "plain": VideoProbeFacts(),
    ], "an edited video is probed again")
    #expect(try await relaunched.passedVideoProbes() == ["hevc", "plain"])
  }

  @Test func onlyHEVCCodecTagsCountAsHEVC() {
    #expect(VideoProbeFacts(codec: "hvc1").isHEVC && VideoProbeFacts(codec: "hev1").isHEVC)
    #expect(!VideoProbeFacts(codec: "avc1").isHEVC && !VideoProbeFacts().isHEVC)
  }

  /// v9: passes recorded before the probe measured anything are dropped, so every video is probed (and measured) again
  /// and stays unselected until then.
  @Test func v9DropsUnmeasuredPassesAndAddsTheFacts() async throws {
    let queue = try DatabaseQueue()
    try Schema.migrator.migrate(queue, upTo: "v8")
    try await queue.write { db in
      try db.execute(sql: "INSERT INTO asset (id, mediaType, subtypes, estBytes) VALUES ('v', 2, 0, 7)")
      try db.execute(sql: "INSERT INTO videoProbe (assetId, verdict, modified, probedAt) VALUES ('v', 'squishable', NULL, 1)")
    }
    let repo = Repositories(try AppDatabase(queue))
    #expect(try await repo.passedVideoProbes().isEmpty)
    let columns = try await queue.read { db in try db.columns(in: "videoProbe").map(\.name) }
    #expect(columns == ["assetId", "verdict", "modified", "probedAt", "codec", "bytes", "fps"])
  }
}
