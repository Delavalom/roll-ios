import SwiftUI

/// Three columns of square thumbnails, each with a check in its corner; tapping toggles it. Unselected photos dim a
/// little so what goes into the album stands out.
struct SelectableGrid: View {
  let ids: [String]
  let isSelected: (String) -> Bool
  let toggle: (String) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 4) {
      ForEach(Array(ids.enumerated()), id: \.element) { index, id in
        let on = isSelected(id)
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
          .onTapGesture {
            withAnimation(Roll.Motion.quick) { toggle(id) }
          }
          .accessibilityElement()
          .accessibilityLabel("Photo \(index + 1)")
          .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
          .accessibilityAction { toggle(id) }
          .accessibilityIdentifier("album.cell.\(index)")
      }
    }
  }
}
