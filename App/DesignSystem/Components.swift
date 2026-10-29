import SwiftUI
import UIKit

// The pieces every screen is built from. Each one uses `Roll` tokens only.

// MARK: - Mark

/// Roll's mark: an ink disc holding a ring and a dot (the roll, and the one photo found in it). While Roll is
/// working the ring becomes a turning arc and the dot breathes.
struct RollMark: View {
  var size: CGFloat = Roll.Size.avatar
  var busy = false

  @State private var turning = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Circle().fill(.rollInk)
      Group {
        if busy {
          Circle()
            .trim(from: 0, to: 0.72)
            .stroke(.rollOnInk, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
        } else {
          Circle().stroke(.rollOnInk, lineWidth: size * 0.075)
        }
      }
      .frame(width: size * 0.5, height: size * 0.5)
      Circle()
        .fill(.rollOnInk)
        .frame(width: size * 0.16, height: size * 0.16)
        .scaleEffect(busy && turning ? 0.7 : 1)
    }
    .frame(width: size, height: size)
    .onAppear { animate() }
    .onChange(of: busy) { animate() }
    .accessibilityHidden(true)
  }

  private func animate() {
    guard busy, !reduceMotion else { turning = false; return }
    turning = false
    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
  }
}

/// The ring alone, drawn as a glyph next to text (stickers).
struct RollRingGlyph: View {
  var size: CGFloat = 11
  var color: Color = .rollInk

  var body: some View {
    ZStack {
      Circle().stroke(color, lineWidth: size * 0.16)
      Circle().fill(color).frame(width: size * 0.32, height: size * 0.32)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

// MARK: - Page

extension View {
  /// The paper page every screen sits on, with ink as the tint.
  func rollPage() -> some View {
    background(Roll.Palette.paper.ignoresSafeArea())
      .scrollContentBackground(.hidden)
      .tint(.rollInk)
  }

  /// A raised card: white surface, 20 pt corners, a hairline and a soft shadow.
  func rollCard(padding: CGFloat = Roll.Space.m, radius: CGFloat = Roll.Radius.card) -> some View {
    self.padding(padding)
      .background(.rollCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth)
      }
      .rollShadow()
  }

  /// The one shadow: soft, low, warm.
  func rollShadow(lifted: Bool = false) -> some View {
    shadow(color: .black.opacity(lifted ? 0.12 : 0.05), radius: lifted ? 22 : 14, y: lifted ? 10 : 5)
  }

  /// Titles carry the tight tracking of the display style.
  func rollTitle(_ font: Font = Roll.Typeface.title, tracking: CGFloat = Roll.Typeface.titleTracking) -> some View {
    self.font(font).tracking(tracking).foregroundStyle(.rollInk)
  }
}

// MARK: - Buttons

/// Capsule buttons, 44 pt tall. Primary is the screen's one main action (ink), secondary sits next to it (card),
/// destructive is the pile's action once confirmed (ember). Pressing shrinks the button a little.
struct RollButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, destructive }
  var kind: Kind = .primary
  var fullWidth = false

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Roll.Typeface.headline)
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, Roll.Space.l)
      .frame(minHeight: Roll.Size.control)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(background, in: Capsule())
      .overlay {
        if kind == .secondary { Capsule().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
      }
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .brightness(configuration.isPressed ? (kind == .secondary ? -0.04 : -0.08) : 0)
      .opacity(isEnabled ? 1 : 0.38)
      .animation(Roll.Motion.press, value: configuration.isPressed)
  }

  private var foreground: Color {
    switch kind {
    case .primary: .rollOnInk
    case .secondary: .rollInk
    case .destructive: .white
    }
  }

  private var background: Color {
    switch kind {
    case .primary: .rollInk
    case .secondary: .rollCard
    case .destructive: .rollEmber
    }
  }
}

extension ButtonStyle where Self == RollButtonStyle {
  static var rollPrimary: RollButtonStyle { RollButtonStyle(kind: .primary) }
  static var rollSecondary: RollButtonStyle { RollButtonStyle(kind: .secondary) }
  static var rollDestructive: RollButtonStyle { RollButtonStyle(kind: .destructive) }
  static func roll(_ kind: RollButtonStyle.Kind, fullWidth: Bool = false) -> RollButtonStyle {
    RollButtonStyle(kind: kind, fullWidth: fullWidth)
  }
}

/// A 36 pt round button for back, undo and close.
struct RollCircleButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.rollInk)
      .frame(width: Roll.Size.circle, height: Roll.Size.circle)
      .background(.rollCard, in: Circle())
      .overlay { Circle().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
      .contentShape(Circle())
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .opacity(isEnabled ? 1 : 0.38)
      .animation(Roll.Motion.press, value: configuration.isPressed)
  }
}

extension ButtonStyle where Self == RollCircleButtonStyle {
  static var rollCircle: RollCircleButtonStyle { RollCircleButtonStyle() }
}

/// A plain text button in ink (links, "Not now").
struct RollTextButtonStyle: ButtonStyle {
  var color: Color = .rollInk

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Roll.Typeface.headline)
      .foregroundStyle(color)
      .opacity(configuration.isPressed ? 0.55 : 1)
      .frame(minHeight: Roll.Size.control)
      .contentShape(Rectangle())
  }
}

extension ButtonStyle where Self == RollTextButtonStyle {
  static var rollText: RollTextButtonStyle { RollTextButtonStyle() }
}

