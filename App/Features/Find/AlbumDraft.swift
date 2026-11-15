import Foundation

/// What a "Make album" grid starts from: the photos it shows, those that start selected, the suggested name, and
/// where it came from (a typed query can become a living album; a living album's offer adds to its saved search).
struct AlbumDraft: Equatable, Sendable {
  /// Every photo the grid shows, in order.
  var ids: [String]
  /// The strong matches: selected at first.
  var preselected: [String]
  var name: String
  /// The typed query, for "Keep this album updated"; nil when the album isn't from one.
  var query: String?
  /// "More like these" picks the answer used (a saved query can't remember them).
  var seeds: [String] = []
  /// A living album's offer: the saved search whose new photos these are. The name is then fixed.
  var savedSearchId: String?
}
