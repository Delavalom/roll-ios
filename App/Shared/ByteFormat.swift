import Foundation

/// Byte counts for the UI. Estimates are always shown as "about" (ADR-0002).
enum ByteFormat {
  /// "1.2 GB", "340 MB".
  static func short(_ bytes: Int64) -> String {
    // The formatter spells zero out ("Zero kB"); "0 MB" reads better next to other sizes.
    bytes <= 0 ? "0 MB" : bytes.formatted(.byteCount(style: .file))
  }

  /// "about 1.2 GB".
  static func about(_ bytes: Int64) -> String { "about \(short(bytes))" }
}
