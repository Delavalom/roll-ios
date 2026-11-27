import SwiftUI

/// Three columns of square thumbnails, each with a check in its corner; tapping toggles it, and a sideways drag across
/// the grid selects (or deselects) every photo it passes, as in Photos (`DragSelectGesture`). Unselected photos dim a
/// little so what goes into the album stands out.
///
/// Interaction rules (docs/investigations/2026-11-27-grid-interactions.md): a cell is a button, so it answers at
/// touch-down (`PressScale`) and a slow press still toggles on release; a drag sets the selection with no animation,
/// so the checks stay under the finger; a tap animates, and a second tap mid-way turns the animation back from where
/// it is.
struct SelectableGrid: View {
  let ids: [String]
  let isSelected: (String) -> Bool
  let toggle: (String) -> Void
  /// A drag started on, or moved over, the photo at an index (out of range past the grid's ends), then ended.
  var dragBegan: (Int) -> Void = { _ in }
  var dragMoved: (Int) -> Void = { _ in }
  var dragEnded: () -> Void = {}

  private static let spacing: CGFloat = 4
  private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
  @State private var width: CGFloat = 0

  var body: some View {
    LazyVGrid(columns: columns, spacing: Self.spacing) {
      ForEach(Array(ids.enumerated()), id: \.element) { index, id in
        let on = isSelected(id)
        Button {
          withAnimation(Roll.Motion.quick) { toggle(id) }
        } label: {
          Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { Thumbnail(id: id, side: 600) }
            .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous)
                .strokeBorder(on ? Roll.Palette.album : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) { PickMark(on: on).padding(6) }
            .opacity(on ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Photo \(index + 1)")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("album.cell.\(index)")
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    // No animation here: the selection follows the finger frame by frame (an eased change trails it by ~0.1 s).
    .gesture(DragSelectGesture(
      index: { [width] in Self.index(at: $0, width: width) },
      began: { i in withTransaction(Transaction(animation: nil)) { dragBegan(i) } },
      moved: { i in withTransaction(Transaction(animation: nil)) { dragMoved(i) } },
      ended: dragEnded))
  }

  /// The cell under a point in the grid's coordinates, reading order; a gap belongs to the cell before it. Above the
  /// grid is negative and below it is past the end (the selection clamps both).
  static func index(at point: CGPoint, width: CGFloat) -> Int {
    let stride = (width - 2 * spacing) / 3 + spacing
    guard stride > spacing else { return 0 }
    let column = min(max(Int((point.x / stride).rounded(.down)), 0), 2)
    let row = Int((point.y / stride).rounded(.down))
    return row * 3 + column
  }
}
