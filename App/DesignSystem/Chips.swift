import SwiftUI
import UIKit

// MARK: - Chips, stickers, tags

/// An outline chip that refines an answer ("Older than a year"); filled with ink while on.
struct RollChip: View {
  let title: String
  var isOn = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(Roll.Typeface.label)
        .lineLimit(1)
        .foregroundStyle(isOn ? .rollOnInk : .rollInk)
        .padding(.horizontal, 14)
        .frame(height: Roll.Size.chip)
        .background(isOn ? Roll.Palette.ink : .clear, in: Capsule())
        .overlay { Capsule().strokeBorder(isOn ? .clear : Roll.Palette.ink.opacity(0.18), lineWidth: Roll.hairlineWidth) }
        .contentShape(Capsule())
    }
    .buttonStyle(PressScale())
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// Lays chips out in rows that wrap: as many as fit on a line, the rest on the next one. Nothing is cut off or
/// scrolled out of view.
struct RollWrap: Layout {
  var spacing: CGFloat = Roll.Space.xs
  var lineSpacing: CGFloat = Roll.Space.xs

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(for: subviews, width: proposal.width ?? .infinity)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(for: subviews, width: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

  private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      if !row.indices.isEmpty, needed > width {
        rows.append(row)
        row = Row()
      }
      row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}

/// Shrinks a custom-drawn button while pressed.
struct PressScale: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .animation(Roll.Motion.press, value: configuration.isPressed)
  }
}

/// Why Roll found something, as a small sticker next to the answer: "Matched by what's on screen".
struct RollSticker: View {
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      RollRingGlyph(size: 11, color: .rollEmber)
      Text(text)
        .font(Roll.Typeface.label)
        .foregroundStyle(.rollInk2)
        .lineLimit(1)
        .contentTransition(.opacity)
    }
    .padding(.horizontal, 10)
    .frame(height: Roll.Size.sticker)
    .background(.rollCard, in: Capsule())
    .overlay { Capsule().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
    .accessibilityElement(children: .combine)
  }
}

/// What a swipe does, on the card while it moves: "● Delete", "● Keep", "● Album", "● Skip".
struct VerdictTag: View {
  let title: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(title).font(Roll.Typeface.label).foregroundStyle(.rollInk)
    }
    .padding(.horizontal, 12)
    .frame(height: 30)
    .background(.rollCard, in: Capsule())
    .overlay { Capsule().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
    .rollShadow()
  }
}

/// "FOUND IN YOUR LIBRARY".
struct SectionLabel: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(Roll.Typeface.eyebrow)
      .tracking(Roll.Typeface.eyebrowTracking)
      .foregroundStyle(.rollInk3)
      .accessibilityAddTraits(.isHeader)
  }
}

