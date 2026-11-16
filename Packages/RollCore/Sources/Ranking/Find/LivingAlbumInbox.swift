import Foundation
import Store

/// What the app holds about living albums between indexing passes: one offer per saved search with new photos
/// ("12 new photos for Soccer"), until the person adds them or says not now. Nothing is ever added without them
/// (`LivingAlbum`): an offer only opens a review grid.
public struct LivingAlbumInbox: Sendable, Equatable {
  public struct Item: Sendable, Equatable, Identifiable {
    public var savedSearchId: String
    public var albumName: String
    public var query: String
    /// New photos, in the answer's order.
    public var ids: [String]
    /// Stored with `Repositories.markSavedSearchRun` once the person has acted on the offer.
    public var watermark: Int64
    public var id: String { savedSearchId }

    /// "12 new photos for Soccer".
    public var title: String { "\(ids.count.formatted()) new \(ids.count == 1 ? "photo" : "photos") for \(albumName)" }
  }

  public private(set) var items: [Item] = []

  public init(items: [Item] = []) { self.items = items }

  /// Records the latest offer for `saved`: replaces its earlier one in place, or appends; an empty offer removes it.
  public mutating func receive(_ offer: LivingAlbum.Offer, for saved: SavedSearchRecord) {
    let item = Item(savedSearchId: saved.id, albumName: saved.albumName, query: saved.query, ids: offer.ids,
                    watermark: offer.watermark)
    if let i = items.firstIndex(where: { $0.savedSearchId == saved.id }) {
      if offer.ids.isEmpty { items.remove(at: i) } else { items[i] = item }
    } else if !offer.ids.isEmpty {
      items.append(item)
    }
  }

  /// Saved searches that no longer exist lose their offers.
  public mutating func keep(only savedSearchIds: Set<String>) {
    items.removeAll { !savedSearchIds.contains($0.savedSearchId) }
  }

  public func item(_ savedSearchId: String) -> Item? { items.first { $0.savedSearchId == savedSearchId } }

  /// The person acted on the offer (added some or all, or "Not now"): it leaves the inbox, and its watermark is what
  /// to store so the same photos aren't offered again.
  @discardableResult
  public mutating func resolve(_ savedSearchId: String) -> Item? {
    guard let i = items.firstIndex(where: { $0.savedSearchId == savedSearchId }) else { return nil }
    return items.remove(at: i)
  }
}

/// "Keep this album updated" on the album-created screen.
public enum KeepUpdatedOffer: Sendable, Equatable {
  /// Offer it.
  case available
  /// A saved search for this query and album already exists.
  case alreadyKept
  /// Not for this album: it wasn't made from a typed query, or "more like these" picked photos that a saved query
  /// can't remember.
  case unavailable

  public static func state(query: String?, seeds: [String], albumName: String, saved: [SavedSearchRecord])
    -> KeepUpdatedOffer {
    guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty, seeds.isEmpty,
          !albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unavailable }
    let folded = query.lowercased()
    if saved.contains(where: { $0.query.lowercased() == folded && $0.albumName == albumName }) { return .alreadyKept }
    return .available
  }
}
