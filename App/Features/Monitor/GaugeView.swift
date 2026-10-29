import SwiftUI

/// One reading as a card: an ink ring on a well track, the figure in display type, and a line under it. `value ==
/// nil` reads "unavailable", never zero. Anything passed as `footer` sits under the reading, on the same card.
struct GaugeView<Footer: View>: View {
  let title: String
  let symbol: String
  let value: Double?
  let detail: String
  @ViewBuilder var footer: Footer

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.s) {
      HStack(spacing: Roll.Space.m) {
        GaugeRing(value: value)
          .frame(width: 60, height: 60)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Image(systemName: symbol)
              .font(Roll.Typeface.label)
              .foregroundStyle(.rollInk3)
            Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
          }
          Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            .font(Roll.Typeface.display.monospacedDigit())
            .tracking(Roll.Typeface.displayTracking)
            .foregroundStyle(value == nil ? .rollInk3 : .rollInk)
            .contentTransition(.numericText())
            .lineLimit(1)
          Text(detail)
            .font(Roll.Typeface.subhead)
            .foregroundStyle(.rollInk2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title)
      .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent, \(detail)" } ?? "Unavailable")
      footer
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .rollCard()
  }
}

extension GaugeView where Footer == EmptyView {
  init(title: String, symbol: String, value: Double?, detail: String) {
    self.init(title: title, symbol: symbol, value: value, detail: detail) { EmptyView() }
  }
}

/// The ring: ink on a well track, starting at the top. Only the track while there's no reading.
private struct GaugeRing: View {
  let value: Double?

  var body: some View {
    GeometryReader { proxy in
      let line = proxy.size.width * 0.12
      ZStack {
        Circle().stroke(.rollWell, lineWidth: line)
        if let value {
          Circle()
            .trim(from: 0, to: min(1, max(0, value)))
            .stroke(.rollInk, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
      }
      .padding(line / 2)
    }
    .animation(Roll.Motion.ease, value: value)
    .accessibilityHidden(true)
  }
}
