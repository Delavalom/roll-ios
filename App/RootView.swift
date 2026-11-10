import SwiftUI

/// Onboarding until it's done, then the three tabs. Squish and Duplicates are reached from Home cards.
struct RootView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingPaywall = RootView.opensPaywall

  /// DEBUG: `-UITestOpen paywall` presents the paywall on launch, over whatever is underneath (screenshots, the
  /// App Store review screenshot, StoreKit testing with Roll.storekit). Release builds ignore it.
  private static var opensPaywall: Bool {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if let i = arguments.firstIndex(of: "-UITestOpen"), i + 1 < arguments.count, arguments[i + 1] == "paywall" {
      return true
    }
    #endif
    return false
  }

  var body: some View {
    Group {
      if app.onboardingComplete {
        MainTabs()
      } else {
        OnboardingView(app: app)
      }
    }
    .environment(\.thumbnails, app.thumbnails)
    .fullScreenCover(isPresented: $showingPaywall) {
      PaywallView(provider: app.entitlements, pitch: app.home.paywallPitch) { showingPaywall = false }
    }
    .qaDebugOverlay()
    .privacyOverlay()
    .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
  }
}

struct MainTabs: View {
  enum Tab: Hashable { case home, swipefiles, monitor }

  @State private var selection: Tab = MainTabs.initialTab

  /// DEBUG: `-UITestTab swipefiles|monitor` opens on that tab (screenshots, UI tests).
  private static var initialTab: Tab {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if let i = arguments.firstIndex(of: "-UITestTab"), i + 1 < arguments.count {
      switch arguments[i + 1] {
      case "swipefiles": return .swipefiles
      case "monitor": return .monitor
      default: break
      }
    }
    #endif
    return .home
  }

  var body: some View {
    TabView(selection: $selection) {
      SwiftUI.Tab("Home", systemImage: "sparkles", value: Tab.home) {
        HomeView(openSwipefiles: { selection = .swipefiles })
      }
      SwiftUI.Tab("Swipefiles", systemImage: "rectangle.stack", value: Tab.swipefiles) {
        SwipefileListView()
      }
      SwiftUI.Tab("Monitor", systemImage: "gauge.with.dots.needle.33percent", value: Tab.monitor) {
        MonitorView()
      }
    }
  }
}

#if DEBUG
#Preview {
  PreviewHost { RootView() }
}
#endif
