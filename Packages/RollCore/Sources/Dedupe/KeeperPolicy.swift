import Foundation
import Store

/// Picks which asset of a duplicate group to keep by default. The user can override it.
public enum KeeperPolicy {
  /// favorite > highest aesthetic > largest pixel count > newest. Remaining ties go to the smallest id.
  /// - Precondition: `group` is not empty (groups from `DuplicateGrouper` always have >= 2).
  public static func keeper(_ group: [AssetRecord]) -> String {
    precondition(!group.isEmpty, "KeeperPolicy.keeper needs at least one record")
    return group.min(by: ranksBefore)!.id
  }

  private static func ranksBefore(_ a: AssetRecord, _ b: AssetRecord) -> Bool {
    if a.isFavorite != b.isFavorite { return a.isFavorite }
    let sa = score(a), sb = score(b)
    if sa != sb { return sa > sb }
    let pa = pixels(a), pb = pixels(b)
    if pa != pb { return pa > pb }
    let ca = a.created ?? -.infinity, cb = b.created ?? -.infinity
    if ca != cb { return ca > cb }
    return a.id < b.id
  }

  /// Missing and NaN scores both rank below every real score.
  private static func score(_ r: AssetRecord) -> Double {
    guard let s = r.aesthetic, !s.isNaN else { return -.infinity }
    return s
  }

  private static func pixels(_ r: AssetRecord) -> Int { (r.pixelW ?? 0) * (r.pixelH ?? 0) }
}
