import Foundation

/// The work a setup run sequences, supplied by the app (its model loader, Indexer and Store).
///
/// Every method asks the world rather than trusting a saved stage: `readyModel` returns quickly when the model is
/// attached, and the installer and the prepare marker skip what's done; `libraryCounts` reads the Store. So a run after
/// an app update, a cache purge, a crash or a killed task does only what's missing.
public protocol SetupWork: Sendable {
  /// Downloads, installs, prepares and attaches the model; returns once it is attached. Throws `SetupBlockError` for a
  /// reason the person can act on, `CancellationError` when stopped, anything else for a failure.
  func readyModel(report: @escaping @Sendable (ModelStep) -> Void) async throws
  /// Photos read so far and in all. Throws when it can't tell (a cancelled task can't read the database): never
  /// guess 0 of 0, which would read as finished.
  func libraryCounts() async throws -> LibraryCounts
  /// Reads the library until nothing is pending locally; reports counts as it goes. Throws like `readyModel`.
  func readLibrary(report: @escaping @Sendable (LibraryCounts) -> Void) async throws
}

/// A reason a step can't go on that the person can act on (`SetupOutcome.blocked`).
public struct SetupBlockError: Error, Sendable, Equatable {
  public let block: SetupBlock
  public init(_ block: SetupBlock) { self.block = block }
}
