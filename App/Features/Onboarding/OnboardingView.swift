import SwiftUI
import UIKit

/// Onboarding (spec §10). The model download never blocks it: the taste scan runs on signals while it loads.
struct OnboardingView: View {
  @State private var model: OnboardingModel

  init(app: AppModel) { _model = State(initialValue: OnboardingModel(app: app)) }

  var body: some View {
    switch model.step {
    case .value:
      ValuePages(model: model)
    case .permission:
      PermissionStep(model: model)
    case .tasteScan:
      TasteScanView(model: model.scan, onContinue: model.next)
    case .paywall:
      PaywallStep(onClose: model.finish)
    }
  }
}

private struct ValuePage: Identifiable {
  enum Hero { case mark, verdicts, privacy }

  let id: Int
  let hero: Hero
  let title: String
  let detail: String

  static let all = [
    ValuePage(id: 0, hero: .mark, title: "Describe it.\nRoll finds it.",
              detail: "Type \"memes\" or \"screenshots of tweets\" and on-device AI gathers them into a pile."),
    ValuePage(id: 1, hero: .verdicts, title: "Swipe to clean",
              detail: "Swipe left to delete, right to keep, up to file it in an album. Every swipe teaches the pile."),
    ValuePage(id: 2, hero: .privacy, title: "Nothing about your photos leaves your phone",
              detail: "Roll's on-device AI looks at your photos on your iPhone. Nothing is uploaded, ever."),
  ]
}

private struct ValuePages: View {
  let model: OnboardingModel

  private var current: Int { if case .value(let p) = model.step { p } else { 0 } }

  private var page: Binding<Int> {
    Binding(get: { current }, set: { model.showPage($0) })
  }

  var body: some View {
    TabView(selection: page) {
      ForEach(ValuePage.all) { item in
        ValuePageView(item: item)
          .tag(item.id)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: Roll.Space.l) {
        PageDots(count: ValuePage.all.count, current: current) { model.showPage($0) }
        Button("Continue", action: model.next)
          .buttonStyle(.roll(.primary, fullWidth: true))
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.top, Roll.Space.s)
      .padding(.bottom, Roll.Space.xs)
    }
    .rollPage()
  }
}

private struct ValuePageView: View {
  let item: ValuePage

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: Roll.Space.xl)
      hero
        .frame(height: 120)
      Text(item.title)
        .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .padding(.top, Roll.Space.xxl)
      Text(item.detail)
        .font(Roll.Typeface.body)
        .foregroundStyle(.rollInk2)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Roll.Space.s)
      Spacer(minLength: Roll.Space.xl)
    }
    .padding(.horizontal, Roll.Space.xxl)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private var hero: some View {
    switch item.hero {
    case .mark:
      RollMark(size: 96)
    case .verdicts:
      // The three swipes, in the colors they carry on the cards.
      VStack(spacing: Roll.Space.s) {
        VerdictTag(title: "Delete", color: .rollEmber).rotationEffect(.degrees(-4))
        VerdictTag(title: "Keep", color: .rollKeep).rotationEffect(.degrees(3))
        VerdictTag(title: "Album", color: .rollAlbum).rotationEffect(.degrees(-2))
      }
      .accessibilityHidden(true)
    case .privacy:
      ZStack(alignment: .bottomTrailing) {
        RollMark(size: 96)
        Image(systemName: "lock.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.rollInk)
          .frame(width: 40, height: 40)
          .background(.rollCard, in: Circle())
          .overlay { Circle().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
          .rollShadow()
          .offset(x: 6, y: 6)
      }
      .accessibilityHidden(true)
    }
  }
}

/// The value pages' dots: ink for the current page, ink3 for the others. One adjustable element for VoiceOver.
private struct PageDots: View {
  let count: Int
  let current: Int
  let select: (Int) -> Void

  var body: some View {
    HStack(spacing: Roll.Space.xs) {
      ForEach(0..<count, id: \.self) { index in
        Capsule()
          .fill(index == current ? Roll.Palette.ink : Roll.Palette.ink3)
          .frame(width: index == current ? 20 : 7, height: 7)
      }
    }
    .animation(Roll.Motion.quick, value: current)
    .accessibilityElement()
    .accessibilityLabel("Page")
    .accessibilityValue("\(current + 1) of \(count)")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: if current + 1 < count { select(current + 1) }
      case .decrement: if current > 0 { select(current - 1) }
      @unknown default: break
      }
    }
  }
}

private struct PermissionStep: View {
  let model: OnboardingModel

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        RollMark(size: 96, busy: model.isRequesting)
          .padding(.top, 72)
        Text("Let Roll look at your photos")
          .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .padding(.top, Roll.Space.xxl)
        Text("Full access lets Roll find everything. With limited access it works on the photos you select.")
          .font(Roll.Typeface.body)
          .foregroundStyle(.rollInk2)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Roll.Space.s)
        RollSticker(text: "Nothing leaves your phone")
          .padding(.top, Roll.Space.l)
        if model.access == .denied {
          RollNotice(symbol: "photo.on.rectangle.angled", title: "Photos access is off",
                     message: "Turn it on in Settings to scan your library.")
            .padding(.top, Roll.Space.xl)
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: Roll.Space.xxs) {
        if model.access == .denied {
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
          .buttonStyle(.roll(.primary, fullWidth: true))
          Button("Continue without access", action: model.continueWithoutAccess)
            .buttonStyle(.rollText)
        } else {
          Button("Continue") {
            Task { await model.requestAccess() }
          }
          .buttonStyle(.roll(.primary, fullWidth: true))
          .disabled(model.isRequesting)
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.top, Roll.Space.s)
      .padding(.bottom, Roll.Space.xs)
      .background(Roll.Palette.paper.ignoresSafeArea(edges: .bottom))
    }
    .rollPage()
  }
}

private struct PaywallStep: View {
  @Environment(AppModel.self) private var app
  let onClose: () -> Void

  var body: some View {
    PaywallView(provider: app.entitlements, onClose: onClose)
  }
}

#if DEBUG
private struct OnboardingPreview: View {
  @Environment(AppModel.self) private var app
  var body: some View { OnboardingView(app: app) }
}

#Preview("Onboarding") {
  PreviewHost(onboarded: false) { OnboardingPreview() }
}
#endif
