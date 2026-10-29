import os

/// Debug-level diagnostics for signal failures. Nothing here logs image content or asset ids.
enum SignalLog {
  static let logger = Logger(subsystem: "com.delavalom.roll", category: "signals")
}
