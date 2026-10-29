import SwiftUI
import UIKit

/// Covers the whole app whenever the scene isn't active, so the app switcher snapshot never shows photos (spec §13:
/// the Private swipefile). The cover is its own window above alerts (`.alert + 1`), so it hides every presentation
/// too: sheets (the commit sheet), full-screen covers (`FullScreenPhoto`) and alerts. It's opaque on purpose; a
/// material could let a blurred photo through.
@MainActor
final class PrivacyShield {
  static let shared = PrivacyShield()

  private var window: UIWindow?

  func update(for phase: ScenePhase) {
    if phase == .active {
      window?.isHidden = true
      window = nil
      return
    }
    guard window == nil, let scene = Self.scene else { return }
    let shield = UIWindow(windowScene: scene)
    shield.windowLevel = .alert + 1
    let host = UIHostingController(rootView: ShieldView())
    host.view.backgroundColor = UIColor(Roll.Palette.paper)
    shield.rootViewController = host
    shield.accessibilityViewIsModal = true
    // Shown without becoming key, so focus and the presentations underneath are left alone.
    shield.isHidden = false
    window = shield
  }

  private static var scene: UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
      ?? scenes.first
  }
}

private struct ShieldView: View {
  var body: some View {
    Roll.Palette.paper
      .overlay { RollMark(size: 64) }
      .ignoresSafeArea()
      .accessibilityHidden(true)
  }
}

/// Drives `PrivacyShield` from the scene phase.
struct PrivacyOverlay: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content
      .onChange(of: scenePhase, initial: true) { _, phase in PrivacyShield.shared.update(for: phase) }
  }
}

extension View {
  func privacyOverlay() -> some View { modifier(PrivacyOverlay()) }
}
