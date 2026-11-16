import Foundation

/// One shot of the cut, on the timeline.
public struct ReelShot: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable { case photo, video }
  public var id: String
  public var kind: Kind
  /// Seconds from the start of the reel.
  public var start: Double
  public var duration: Double
  /// For video: where in the source clip this shot begins (seconds). Zero for photos.
  public var sourceStart: Double

  public init(id: String, kind: Kind, start: Double, duration: Double, sourceStart: Double = 0) {
    self.id = id; self.kind = kind; self.start = start; self.duration = duration; self.sourceStart = sourceStart
  }
  public var end: Double { start + duration }
}

public enum ReelProblem: Sendable, Equatable {
  case notEnoughPhotos(have: Int, need: Int)

  public var message: String {
    switch self {
    case .notEnoughPhotos(let have, let need): "Not enough photos for a memory video: \(have) usable, \(need) needed."
    }
  }
}

public struct ReelPlan: Sendable, Equatable {
  public var shots: [ReelShot]
  public var problem: ReelProblem?
  public var duration: Double { shots.last?.end ?? 0 }
  public var isUsable: Bool { problem == nil && !shots.isEmpty }
  public init(shots: [ReelShot], problem: ReelProblem? = nil) { self.shots = shots; self.problem = problem }
}
