import SwiftUI
import UIKit

/// Roll's design tokens: the only place colors, type, radii, borders, shadows and motion are defined. Views use
/// these (and the components in `Components.swift`), never raw values or system tints. See
/// `docs/design/design-system.md` for the rules behind them.
///
/// The palette is warm paper and ink with one brand accent (ember). Green and blue carry meaning only: green is
/// "keep", blue is "album". Ember is the pile's action, never decoration.
enum Roll {
  // MARK: Color

  enum Palette {
    /// The page. Warm off-white; a warm near-black in dark mode.
    static let paper = dynamic(light: 0xF6F4EF, dark: 0x11110F)
    /// Raised surfaces: cards, the composer, sheets' rows.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1D1C1A)
    /// A sunken surface: image placeholders, tracks, the pressed state of a card.
    static let well = dynamic(light: 0xEDEAE3, dark: 0x262522)
    /// Primary text and the primary button.
    static let ink = dynamic(light: 0x141414, dark: 0xF4F2EC)
    /// Secondary text.
    static let ink2 = dynamic(light: 0x6E6A62, dark: 0xA39E94)
    /// Tertiary text: section labels, placeholders, disabled.
    static let ink3 = dynamic(light: 0xA8A39A, dark: 0x6D6961)
    /// Text and icons on an ink fill.
    static let onInk = dynamic(light: 0xF6F4EF, dark: 0x141414)
    /// The one-pixel border every surface carries.
    static let hairline = dynamic(light: 0x141414, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// The brand accent and the pile's action (delete, squish).
    static let ember = Color(hex: 0xFF5A36)
    /// "Keep".
    static let keep = Color(hex: 0x2FB45A)
    /// "Add to album".
    static let album = Color(hex: 0x2F7CF6)

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
      Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
      })
    }
  }

  // MARK: Type

  /// System type (SF Pro), scaled with Dynamic Type. Display and titles are tightly tracked; everything else is
  /// left at the system's tracking.
  enum Typeface {
    /// "What should we clear today?" — one per screen.
    static let display = Font.system(.largeTitle, weight: .bold)
    static let displayTracking: CGFloat = -0.9
    /// An answer's or a section's title: "Screenshots of chats".
    static let title = Font.system(.title2, weight: .bold)
    static let titleTracking: CGFloat = -0.4
    /// Card titles, buttons.
    static let headline = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let callout = Font.system(.callout)
    /// Lines under titles, card counts.
    static let subhead = Font.system(.subheadline)
    /// Stickers, verdict tags, chips.
    static let label = Font.system(.footnote, weight: .semibold)
    static let caption = Font.system(.caption)
    /// "FOUND IN YOUR LIBRARY": uppercase with `eyebrowTracking`.
    static let eyebrow = Font.system(.caption2, weight: .semibold)
    static let eyebrowTracking: CGFloat = 1.1
    /// Sizes and counts that change in place.
    static let figure = Font.system(.subheadline, weight: .semibold).monospacedDigit()
  }

  // MARK: Shape

  enum Radius {
    /// Grid cells, thumbnails.
    static let cell: CGFloat = 12
    /// A swipe card's photo, inset in its card.
    static let photo: CGFloat = 18
    /// Cards and grouped rows.
    static let card: CGFloat = 20
    /// The swipe card.
    static let deck: CGFloat = 24
    /// Sheets and big panels.
    static let panel: CGFloat = 28
  }

  enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// The page's side margin.
    static let page: CGFloat = 20
  }

  enum Size {
    /// Buttons and the action bar's buttons.
    static let control: CGFloat = 44
    /// The composer.
    static let composer: CGFloat = 56
    /// Refine chips.
    static let chip: CGFloat = 34
    /// Stickers.
    static let sticker: CGFloat = 26
    /// Back, undo, close.
    static let circle: CGFloat = 36
    /// The Roll mark as an avatar in a chat turn.
    static let avatar: CGFloat = 28
  }

  /// One border width everywhere.
  static let hairlineWidth: CGFloat = 1

  // MARK: Motion

  enum Motion {
    /// Things settling into place: reveals, layout changes. cubic-bezier(.2, .8, .2, 1).
    static let ease = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45)
    static let quick = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
    /// Things arriving: cards flying in, the done ring, chips appearing. Slight overshoot.
    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    /// A card leaving the deck.
    static let exit = Animation.easeIn(duration: 0.22)
    /// A button press.
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.6)
  }
}

extension Color {
  init(hex: UInt32, alpha: Double = 1) {
    self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: alpha)
  }
}

extension UIColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
              blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
}

extension ShapeStyle where Self == Color {
  static var rollPaper: Color { Roll.Palette.paper }
  static var rollCard: Color { Roll.Palette.card }
  static var rollWell: Color { Roll.Palette.well }
  static var rollInk: Color { Roll.Palette.ink }
  static var rollInk2: Color { Roll.Palette.ink2 }
  static var rollInk3: Color { Roll.Palette.ink3 }
  static var rollOnInk: Color { Roll.Palette.onInk }
  static var rollHairline: Color { Roll.Palette.hairline }
  static var rollEmber: Color { Roll.Palette.ember }
  static var rollKeep: Color { Roll.Palette.keep }
  static var rollAlbum: Color { Roll.Palette.album }
}
