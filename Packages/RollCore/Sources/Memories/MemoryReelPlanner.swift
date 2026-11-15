import Foundation

/// Picks and orders the shots of a memory reel. Pure: no PhotoKit, no I/O.
///
/// Rules, in order: drop screenshots and documents; keep one shot (the keeper) per similar-shot group; choose about as
/// many shots as fit the target, spread across the span of the trip (equal-sized buckets in time order, the best aesthetic of
/// each); cut chronologically; give every shot a length on the beat grid
/// (photos `photoBeats`, the first and last longer, video clips `videoBeats` from their middle); trim the weakest
/// middle shots until the cut is within one photo of the target.
public enum MemoryReelPlanner {
  public static func plan(candidates: [ReelCandidate], target: ReelTarget = .standard) -> ReelPlan {
    let usable = dedupe(candidates.filter { !$0.isScreenshotOrDocument && usableLength($0, target) != nil })
    guard usable.count >= target.minimumShots else {
      return ReelPlan(shots: [], problem: .notEnoughPhotos(have: usable.count, need: target.minimumShots))
    }
    let photoSeconds = Double(target.photoBeats) * target.beat
    let edgeSeconds = Double(target.edgeExtraBeats) * target.beat
    let wanted = max(target.minimumShots, Int(((target.seconds - 2 * edgeSeconds) / photoSeconds).rounded()))
    var chosen = pick(usable, count: min(wanted, usable.count))

    func total(_ list: [ReelCandidate]) -> Double {
      list.enumerated().reduce(0) { $0 + length(of: $1.element, index: $1.offset, count: list.count, target) }
    }
    // Videos run longer than photos: drop the weakest middle shot while over the target by more than a photo.
    while chosen.count > target.minimumShots, total(chosen) > target.seconds + photoSeconds {
      let middle = chosen.indices.dropFirst().dropLast()
      guard let weakest = middle.min(by: { score(chosen[$0]) < score(chosen[$1]) }) else { break }
      chosen.remove(at: weakest)
    }
    return ReelPlan(shots: timeline(chosen, target))
  }

  // MARK: - Steps

  /// One shot per similar group: the keeper, or the best remaining member if the keeper was filtered out.
  static func dedupe(_ list: [ReelCandidate]) -> [ReelCandidate] {
    var best: [String: ReelCandidate] = [:]
    var singles: [ReelCandidate] = []
    for c in list {
      guard let group = c.similarGroup else { singles.append(c); continue }
      guard let current = best[group] else { best[group] = c; continue }
      if c.isKeeper != current.isKeeper {
        if c.isKeeper { best[group] = c }
      } else if !lowerScore(c, current) { best[group] = c }
    }
    return singles + best.values
  }

  /// `count` shots spread over the trip: the shots in time order are cut into `count` equal-sized buckets (by rank, so a
  /// trip shot in two bursts days apart still gets shots from both, in proportion), then the best aesthetic of each.
  static func pick(_ list: [ReelCandidate], count: Int) -> [ReelCandidate] {
    let sorted = list.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    guard count < sorted.count else { return sorted }
    let chosen = (0..<count).compactMap { b -> ReelCandidate? in
      let lo = b * sorted.count / count, hi = (b + 1) * sorted.count / count
      return sorted[lo..<hi].max(by: lowerScore)
    }
    return chosen
  }

  static func timeline(_ list: [ReelCandidate], _ target: ReelTarget) -> [ReelShot] {
    var shots: [ReelShot] = []
    var clock = 0.0
    for (i, c) in list.enumerated() {
      let seconds = length(of: c, index: i, count: list.count, target)
      let sourceStart = c.isVideo ? max(0, (c.duration - seconds) / 2) : 0
      shots.append(ReelShot(id: c.id, kind: c.isVideo ? .video : .photo, start: clock, duration: seconds, sourceStart: sourceStart))
      clock += seconds
    }
    return shots
  }

  // MARK: - Lengths and scores

  /// Seconds a clip can fill on the beat grid; nil when a video is too short to use.
  static func usableLength(_ c: ReelCandidate, _ target: ReelTarget) -> Double? {
    guard c.isVideo else { return Double(target.photoBeats) * target.beat }
    let beats = Int((c.duration / target.beat).rounded(.down))
    return beats >= target.videoBeats.lowerBound ? Double(min(beats, target.videoBeats.upperBound)) * target.beat : nil
  }

  static func length(of c: ReelCandidate, index: Int, count: Int, _ target: ReelTarget) -> Double {
    let base = usableLength(c, target) ?? Double(target.photoBeats) * target.beat
    let edge = (index == 0 || index == count - 1) ? Double(target.edgeExtraBeats) * target.beat : 0
    return base + edge
  }

  static func score(_ c: ReelCandidate) -> Double {
    guard let a = c.aesthetic, !a.isNaN else { return -.infinity }
    return a
  }

  /// Strict order for choosing: lower score first, then later id (so ties are deterministic).
  static func lowerScore(_ a: ReelCandidate, _ b: ReelCandidate) -> Bool {
    let sa = score(a), sb = score(b)
    return sa != sb ? sa < sb : a.id > b.id
  }
}
