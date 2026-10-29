import SwiftUI
import UIKit

// MARK: - Status line, done ring, thumbnail fan

/// What Roll is doing, in one line: shimmering while it works, a check when done ("Compared on this iPhone in
/// 0.09 s"). Times shown here are measured, never staged.
struct StatusLine: View {
  let text: String
  var done = false

  @State private var phase: CGFloat = -1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 6) {
      if done {
        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.rollKeep)
          .transition(.scale.combined(with: .opacity))
      }
      Text(text)
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .overlay {
          if !done && !reduceMotion {
            GeometryReader { proxy in
              LinearGradient(colors: [.clear, Roll.Palette.paper.opacity(0.85), .clear], startPoint: .leading,
                             endPoint: .trailing)
                .frame(width: proxy.size.width * 0.45)
                .offset(x: phase * proxy.size.width)
            }
            .mask(Text(text).font(Roll.Typeface.subhead))
          }
        }
    }
    .onAppear {
      withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
    }
    .animation(Roll.Motion.quick, value: done)
    .accessibilityElement(children: .combine)
  }
}

/// The mark's ring closing into a full circle around its dot: the "done" moment after applying.
struct DoneRing: View {
  var size: CGFloat = 64
  @State private var progress: CGFloat = 0

  var body: some View {
    ZStack {
      Circle().stroke(.rollWell, lineWidth: size * 0.083)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(.rollInk, style: StrokeStyle(lineWidth: size * 0.083, lineCap: .round))
        .rotationEffect(.degrees(-90))
      Circle().fill(.rollInk).frame(width: size * 0.21, height: size * 0.21)
    }
    .frame(width: size, height: size)
    .padding(size * 0.04)
    .onAppear { withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.9)) { progress = 1 } }
    .accessibilityHidden(true)
  }
}

/// Up to three thumbnails fanned out, for suggestion cards.
struct ThumbFan: View {
  let ids: [String]
  var side: CGFloat = 46

  var body: some View {
    ZStack {
      ForEach(Array(ids.prefix(3).enumerated()), id: \.element) { index, id in
        let count = min(ids.count, 3)
        let offset = CGFloat(index) - CGFloat(count - 1) / 2
        Thumbnail(id: id, side: 160)
          .frame(width: side, height: side)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.rollCard, lineWidth: 2)
          }
          .rotationEffect(.degrees(Double(offset) * 9))
          .offset(x: offset * side * 0.42, y: abs(offset) * 3)
          .zIndex(Double(index == count / 2 ? 2 : 1))
          .rollShadow()
      }
    }
    .frame(width: side * 1.9, height: side + 8)
    .accessibilityHidden(true)
  }
}

// MARK: - System chrome

/// Navigation and tab bars in brand: paper, ink, no system blue. Applied once at launch.
@MainActor
enum RollAppearance {
  static func apply() {
    // Built as UIKit dynamic colors directly: bar attributes don't resolve a SwiftUI-wrapped provider reliably.
    func dynamic(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> UIColor {
      UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha.1) : UIColor(hex: light, alpha: alpha.0) }
    }
    let paper = dynamic(0xF6F4EF, 0x11110F), ink = dynamic(0x141414, 0xF4F2EC)
    let ink3 = dynamic(0xA8A39A, 0x6D6961), hairline = dynamic(0x141414, 0xFFFFFF, alpha: (0.08, 0.10))

    let nav = UINavigationBarAppearance()
    nav.configureWithOpaqueBackground()
    nav.backgroundColor = paper
    nav.shadowColor = .clear
    nav.titleTextAttributes = [.foregroundColor: ink, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
    let large = UIFont.systemFont(ofSize: 34, weight: .bold)
    nav.largeTitleTextAttributes = [.foregroundColor: ink, .font: large, .kern: Roll.Typeface.displayTracking]
    // iOS 26's glass bars already sit on the page's paper; a custom appearance there hides their titles.
    if #unavailable(iOS 26) {
      UINavigationBar.appearance().standardAppearance = nav
      UINavigationBar.appearance().compactAppearance = nav
      UINavigationBar.appearance().scrollEdgeAppearance = nav
    }
    UINavigationBar.appearance().tintColor = ink

    let tab = UITabBarAppearance()
    tab.configureWithOpaqueBackground()
    tab.backgroundColor = paper
    tab.shadowColor = hairline
    for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
      item.normal.iconColor = ink3
      item.normal.titleTextAttributes = [.foregroundColor: ink3]
      item.selected.iconColor = ink
      item.selected.titleTextAttributes = [.foregroundColor: ink]
    }
    UITabBar.appearance().standardAppearance = tab
    UITabBar.appearance().scrollEdgeAppearance = tab

    UISwitch.appearance().onTintColor = ink
    UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = ink
  }
}
