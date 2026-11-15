import Foundation

/// How long the reel should be and the beat grid its cuts snap to.
public struct ReelTarget: Sendable, Equatable {
  public var seconds: Double
  public var bpm: Double
  /// A photo holds for this many beats (4 beats = 2.0 s at 120 bpm).
  public var photoBeats: Int
  /// The first and last shot hold longer, by this many beats each (a settle and an out).
  public var edgeExtraBeats: Int
  /// Video clips run between these many beats.
  public var videoBeats: ClosedRange<Int>
  public var minimumShots: Int

  public init(seconds: Double = 30, bpm: Double = 120, photoBeats: Int = 4, edgeExtraBeats: Int = 2,
              videoBeats: ClosedRange<Int> = 4...8, minimumShots: Int = 6) {
    self.seconds = seconds; self.bpm = bpm; self.photoBeats = photoBeats; self.edgeExtraBeats = edgeExtraBeats
    self.videoBeats = videoBeats; self.minimumShots = minimumShots
  }

  public static let short = ReelTarget(seconds: 15)
  public static let standard = ReelTarget(seconds: 30)
  public static let long = ReelTarget(seconds: 60)

  public var beat: Double { 60 / bpm }
}
