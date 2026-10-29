import Foundation
import GRDB

/// What Squish's probe measured about a local video whose format passed (v9). The planner uses it instead of the
/// bitrate table: an HEVC file already about as compact as a squish would make it isn't offered. Every field is
/// optional: nil means the probe couldn't read it, and the planner falls back to its estimate for that part.
public struct VideoProbeFacts: Sendable, Equatable {
  /// The first video track's codec as its four-character code ("hvc1", "avc1", ...).
  public var codec: String?
  /// The original file's size in bytes.
  public var bytes: Int64?
  /// The video track's nominal frame rate.
  public var fps: Double?

  public init(codec: String? = nil, bytes: Int64? = nil, fps: Double? = nil) {
    self.codec = codec; self.bytes = bytes; self.fps = fps
  }

  /// HEVC ('hvc1', 'hev1'). Dolby Vision's 'dvh1'/'dvhe' never get here: the probe refuses them.
  public var isHEVC: Bool { codec == "hvc1" || codec == "hev1" }
}

extension Repositories {
  /// Remembers that `assetId`'s video format passed Squish's probe (not Dolby Vision, ProRes or Apple Log), with the
  /// asset's current `modified` date and what the probe measured. Refused formats are remembered as squish refusals
  /// instead. Unknown ids are ignored; one row per asset.
  public func recordVideoProbePassed(assetId: String, facts: VideoProbeFacts = VideoProbeFacts(),
                                     at date: Date = Date()) async throws {
    try await database.writer.write { db in
      try db.execute(sql: """
        INSERT OR REPLACE INTO videoProbe (assetId, verdict, modified, probedAt, codec, bytes, fps)
        SELECT id, 'squishable', modified, ?, ?, ?, ? FROM asset WHERE id = ?
        """, arguments: [date.timeIntervalSince1970, facts.codec, facts.bytes, facts.fps, assetId])
    }
  }

  /// Live videos whose probe passed and that haven't changed since (`modified` unchanged).
  public func passedVideoProbes() async throws -> Set<String> {
    Set(try await videoProbeFacts().keys)
  }

  /// What the probe measured, for the live videos whose probe passed and that haven't changed since.
  public func videoProbeFacts() async throws -> [String: VideoProbeFacts] {
    try await database.writer.read { db in
      let rows = try Row.fetchAll(db, sql: """
        SELECT p.assetId, p.codec, p.bytes, p.fps FROM videoProbe p JOIN asset a ON a.id = p.assetId
        WHERE a.deleted = 0 AND a.modified IS p.modified AND p.verdict = 'squishable'
        """)
      return Dictionary(rows.map { row in
        (row["assetId"] as String, VideoProbeFacts(codec: row["codec"], bytes: row["bytes"], fps: row["fps"]))
      }, uniquingKeysWith: { first, _ in first })
    }
  }
}
