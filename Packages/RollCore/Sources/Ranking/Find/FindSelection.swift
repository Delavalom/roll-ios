import Foundation

/// The "Make album" grid: which of an answer's photos go into the album, and its name. Strong matches start selected;
/// tapping toggles; the order of `ids` is the order photos are added in.
public struct AlbumSelection: Sendable, Equatable {
  public private(set) var ids: [String]
  public private(set) var selected: Set<String>
  public var name: String

  /// - Parameters:
  ///   - ids: every photo the grid shows, in order (duplicates dropped).
  ///   - preselected: those that start selected (the strong matches); others in it are ignored.
  public init(ids: [String], preselected: some Sequence<String>, name: String) {
    var seen = Set<String>()
    self.ids = ids.filter { seen.insert($0).inserted }
    selected = Set(preselected).intersection(seen)
    self.name = name
  }

  public var count: Int { selected.count }
  public var allSelected: Bool { !ids.isEmpty && selected.count == ids.count }
  public func isSelected(_ id: String) -> Bool { selected.contains(id) }

  public mutating func toggle(_ id: String) {
    guard ids.contains(id) else { return }
    if selected.remove(id) == nil { selected.insert(id) }
  }

  /// A drag across the grid, as in Photos: the first photo flips, and every photo between it and the finger (in grid
  /// order) takes that new state; photos the drag leaves again go back to how they were before it.
  private struct Drag: Sendable, Equatable {
    let anchor: Int
    let selecting: Bool
    let before: Set<String>
  }

  private var drag: Drag?

  /// Starts a drag on the photo at `index` (clamped to the grid) and flips it.
  public mutating func beginDrag(at index: Int) {
    guard !ids.isEmpty else { return }
    let anchor = clamped(index)
    drag = Drag(anchor: anchor, selecting: !selected.contains(ids[anchor]), before: selected)
    continueDrag(to: anchor)
  }

  /// The finger is over the photo at `index` (clamped to the grid).
  public mutating func continueDrag(to index: Int) {
    guard let drag else { return }
    let end = clamped(index)
    let range = ids[min(drag.anchor, end)...max(drag.anchor, end)]
    selected = drag.selecting ? drag.before.union(range) : drag.before.subtracting(range)
  }

  public mutating func endDrag() { drag = nil }

  private func clamped(_ index: Int) -> Int { min(max(index, 0), ids.count - 1) }

  public mutating func selectAll() { selected = Set(ids) }
  public mutating func deselectAll() { selected = [] }

  /// The selection in the grid's order: what Create adds.
  public var orderedSelection: [String] { ids.filter(selected.contains) }

  public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  public var canCreate: Bool { count > 0 && !trimmedName.isEmpty }

  /// "Add 24 photos", for the Create button.
  public var createTitle: String { "Add \(count.formatted()) \(count == 1 ? "photo" : "photos")" }

  /// The album name an answer suggests: the query with a capital first letter ("Soccer").
  public static func defaultName(query: String) -> String {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return q.prefix(1).uppercased() + q.dropFirst()
  }
}

/// "More like these": 1 to `limit` photos picked from an answer become the seeds of the next search (V5).
public struct SeedPick: Sendable, Equatable {
  public static let limit = 3
  public private(set) var ids: [String] = []

  public init(ids: [String] = []) { self.ids = Array(ids.prefix(Self.limit)) }

  /// Adds or removes `id`; adding past the limit does nothing.
  public mutating func toggle(_ id: String) {
    if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else if ids.count < Self.limit { ids.append(id) }
  }

  public func contains(_ id: String) -> Bool { ids.contains(id) }
  public var isFull: Bool { ids.count >= Self.limit }
  public var canSearch: Bool { !ids.isEmpty }

  /// "Find more like these (2)", or a hint before any is picked.
  public var actionTitle: String {
    ids.isEmpty ? "Pick up to \(Self.limit) photos" : "More like \(ids.count == 1 ? "this one" : "these \(ids.count)")"
  }

  /// The refinement chip once searched: "Like 2 photos".
  public static func chipTitle(_ count: Int) -> String { "Like \(count) \(count == 1 ? "photo" : "photos")" }
}
