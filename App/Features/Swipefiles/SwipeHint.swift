import Store
import SwiftUI

/// The swipes, explained once, on the card stack where they're used (onboarding no longer has a page for them). Shown
/// until it's closed or the first card is swiped, then never again: the flag lives in the app's defaults, and
/// `-UITestResetState` clears it with the onboarding flag.
struct SwipeHint: View {
  static let seenKey = "swipeHintSeen"

  let action: SwipefileAction
  let learns: Bool
  let close: () -> Void

  static func isNeeded(_ defaults: UserDefaults) -> Bool { !defaults.bool(forKey: seenKey) }
  static func markSeen(_ defaults: UserDefaults) { defaults.set(true, forKey: seenKey) }

  /// "Swipe left to delete, right to keep, up to add to an album. Every swipe teaches the pile."
  static func text(action: SwipefileAction, learns: Bool) -> String {
    let swipes = switch action {
    case .delete: "Swipe left to delete, right to keep, up to add to an album."
    case .album: "Swipe left to add to the album, right to keep."
    case .squish: "Swipe left to squish, right to keep."
    }
    return learns ? swipes + " Every swipe teaches the pile." : swipes
  }

  var body: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      Image(systemName: "hand.draw")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.rollInk)
        .accessibilityHidden(true)
      Text(Self.text(action: action, learns: learns))
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Got it", systemImage: "xmark", action: close)
        .labelStyle(.iconOnly)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.rollInk2)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .accessibilityIdentifier("swipe.hint.close")
    }
    .padding(.horizontal, Roll.Space.m)
    .padding(.vertical, Roll.Space.s)
    .background(.rollCard, in: RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous)
        .strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("swipe.hint")
  }
}
