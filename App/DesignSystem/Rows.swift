import SwiftUI
import UIKit

// MARK: - Groups and rows

/// Rows grouped on one card, divided by hairlines (settings-like lists, sheet contents).
struct RollGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { Rectangle().fill(.rollHairline).frame(height: Roll.hairlineWidth).padding(.leading, Roll.Space.m) }
          row
        }
      }
    }
    .background(.rollCard, in: RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous)
        .strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth)
    }
  }
}

/// One row: an icon tile, a title with a detail line, and an optional trailing figure.
struct RollRow: View {
  var symbol: String?
  let title: String
  var detail: String?
  var trailing: String?
  var showsChevron = false

  var body: some View {
    HStack(spacing: Roll.Space.s) {
      if let symbol { RollIconTile(symbol: symbol) }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
        if let detail { Text(detail).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2) }
      }
      Spacer(minLength: Roll.Space.xs)
      if let trailing { Text(trailing).font(Roll.Typeface.figure).foregroundStyle(.rollInk2) }
      if showsChevron {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.rollInk3)
      }
    }
    .padding(.horizontal, Roll.Space.m)
    .padding(.vertical, Roll.Space.s)
    .frame(minHeight: 56)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// A symbol on a soft square, 36 pt.
struct RollIconTile: View {
  let symbol: String
  var color: Color = .rollInk

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: 36, height: 36)
      .background(.rollWell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .accessibilityHidden(true)
  }
}

/// A slim ink bar on a well track.
struct RollProgressBar: View {
  let value: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.rollWell)
        Capsule().fill(.rollInk).frame(width: proxy.size.width * min(1, max(0, value)))
      }
    }
    .frame(height: 4)
    .animation(Roll.Motion.ease, value: value)
    .accessibilityElement()
    .accessibilityValue(Text("\(Int((value * 100).rounded())) percent"))
  }
}

/// A notice card: an icon tile, a title, a line, and an optional action (model status, recovery, access).
struct RollNotice: View {
  let symbol: String
  let title: String
  let message: String
  var action: (title: String, perform: () -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      RollIconTile(symbol: symbol)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
        Text(message).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2).fixedSize(horizontal: false, vertical: true)
        if let action {
          Button(action.title, action: action.perform)
            .buttonStyle(.rollSecondary)
            .controlSize(.small)
            .padding(.top, 6)
        }
      }
      Spacer(minLength: 0)
    }
    .rollCard()
  }
}

/// An empty or blocked screen, in brand: the mark, a title, a line and actions.
struct RollEmptyState<Actions: View>: View {
  let title: String
  let message: String
  var busy = false
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(spacing: Roll.Space.s) {
      RollMark(size: 48, busy: busy).padding(.bottom, Roll.Space.xs)
      Text(title).rollTitle().multilineTextAlignment(.center)
      Text(message)
        .font(Roll.Typeface.callout)
        .foregroundStyle(.rollInk2)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      actions.padding(.top, Roll.Space.xs)
    }
    .padding(Roll.Space.xl)
    .frame(maxWidth: .infinity)
  }
}

extension RollEmptyState where Actions == EmptyView {
  init(title: String, message: String, busy: Bool = false) {
    self.init(title: title, message: message, busy: busy) { EmptyView() }
  }
}

