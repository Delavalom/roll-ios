import Foundation

/// Where the model is in getting ready (the app maps its install steps and prepare progress onto these).
public enum ModelStep: Sendable, Equatable {
  /// Queued until the network allows the download (Wi-Fi, or Low Data Mode off).
  case waiting(SetupWait)
  case downloading(completedBytes: Int64, totalBytes: Int64)
  /// Unpacking and loading (the first load compiles the model).
  case installing
  /// Compiling the model's functions for the Neural Engine, one at a time: `done` of `total` finished.
  case preparing(done: Int, total: Int)
}

public enum SetupWait: Sendable, Equatable {
  case wifi
  case lowDataMode
}

/// Photos read (Vision signals and the embedding both done) and photos in all.
public struct LibraryCounts: Sendable, Equatable {
  public var read: Int
  public var total: Int

  public init(read: Int, total: Int) {
    self.read = max(0, min(read, total))
    self.total = max(0, total)
  }

  public var isComplete: Bool { read >= total }
}

/// What a setup run is doing.
public enum SetupStage: Sendable, Equatable {
  /// Not looked at yet (before the first run).
  case unknown
  case model(ModelStep)
  case library(LibraryCounts)
  case done(LibraryCounts)
}

/// Why a run stopped short of done; the next run tries again.
public enum SetupBlock: Sendable, Equatable {
  case noPhotoAccess
  case notEnoughSpace(requiredBytes: Int64)
  /// The step's error, described (it's logged; the UI says it didn't finish).
  case failed(String)
}

public enum SetupOutcome: Sendable, Equatable {
  case finished(LibraryCounts)
  /// Every lease was released (the app left, the task expired or was cancelled): the next run resumes.
  case stopped
  case blocked(SetupBlock)
}

/// A run's stage plus one fraction for a single progress bar (iOS's progress for the continued task).
public struct SetupProgress: Sendable, Equatable {
  public var stage: SetupStage
  /// 0...1 over the whole setup, never lower than an earlier value of the same run (`SetupCoordinator`).
  public var overall: Double

  public init(stage: SetupStage, overall: Double) {
    self.stage = stage
    self.overall = overall
  }

  public static let initial = SetupProgress(stage: .unknown, overall: 0)

  /// Shares of the bar: the model's three steps, then the library read.
  public static let downloadShare = 0.15
  public static let installEnd = 0.20
  public static let modelEnd = 0.35

  /// How long a step with no counter of its own is expected to take, for the creep (`creep(_:expected:)`).
  public static let installExpected: Duration = .seconds(60)
  public static let functionExpected: Duration = .seconds(120)

  /// `stage`'s place on the bar. `elapsed`: time since the current step last moved (an install or one function's
  /// compile), so a long step creeps forward on its time estimate and never looks stalled.
  public static func fraction(of stage: SetupStage, elapsed: Duration = .zero) -> Double {
    switch stage {
    case .unknown, .model(.waiting):
      return 0
    case .model(.downloading(let done, let total)):
      return downloadShare * ratio(Double(done), Double(total))
    case .model(.installing):
      return downloadShare + (installEnd - downloadShare) * creep(elapsed, expected: installExpected)
    case .model(.preparing(let done, let total)):
      guard total > 0 else { return installEnd }
      let compiling = done < total ? creep(elapsed, expected: functionExpected) : 0
      return installEnd + (modelEnd - installEnd) * ratio(Double(done) + compiling, Double(total))
    case .library(let counts):
      return modelEnd + (1 - modelEnd) * ratio(Double(counts.read), Double(counts.total))
    case .done:
      return 1
    }
  }

  /// 0 at the start of a step, 0.63 at its expected length, never past 0.95: a step that runs long still moves
  /// but never reaches where the next one starts.
  public static func creep(_ elapsed: Duration, expected: Duration) -> Double {
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let scale = Double(expected.components.seconds)
    guard seconds > 0, scale > 0 else { return 0 }
    return min(0.95, 1 - exp(-seconds / scale))
  }

  private static func ratio(_ part: Double, _ whole: Double) -> Double {
    whole > 0 ? min(1, max(0, part / whole)) : 0
  }
}
