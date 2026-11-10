import Overview
import SwiftUI
import UIKit

/// Onboarding (spec §10). The model download never blocks it: the taste scan runs on signals while it loads.
struct OnboardingView: View {
  @State private var model: OnboardingModel

  init(app: AppModel) { _model = State(initialValue: OnboardingModel(app: app)) }

  var body: some View {
    switch model.step {
    case .intro:
      IntroStep(model: model)
    case .permission:
      PermissionStep(model: model)
    case .tasteScan:
      TasteScanView(model: model.scan, onContinue: model.next)
    case .paywall:
      PaywallStep(pitch: model.paywallPitch, onClose: model.finish)
    }
  }
}

/// The one page before the permission ask: the hook and the privacy promise together. The aha (the taste scan's
/// number) comes right after the permission, so nothing else stands in front of it.
private struct IntroStep: View {
  let model: OnboardingModel

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: Roll.Space.xl)
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
      .frame(height: 120)
      .accessibilityHidden(true)
      Text("Describe it.\nRoll finds it.")
        .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .padding(.top, Roll.Space.xxl)
      Text("Type \"memes\" or \"screenshots of tweets\" and on-device AI gathers them into a pile.")
        .font(Roll.Typeface.body)
        .foregroundStyle(.rollInk2)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Roll.Space.s)
      Text("Nothing about your photos leaves your phone.")
        .font(Roll.Typeface.headline)
        .foregroundStyle(.rollInk)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Roll.Space.m)
      Spacer(minLength: Roll.Space.xl)
    }
    .padding(.horizontal, Roll.Space.xxl)
    .frame(maxWidth: .infinity)
    .safeAreaInset(edge: .bottom) {
      Button("Continue", action: model.next)
        .buttonStyle(.roll(.primary, fullWidth: true))
        .padding(.horizontal, Roll.Space.page)
        .padding(.top, Roll.Space.s)
        .padding(.bottom, Roll.Space.xs)
    }
    .rollPage()
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
  let pitch: PaywallPitch?
  let onClose: () -> Void

  var body: some View {
    PaywallView(provider: app.entitlements, pitch: pitch, onClose: onClose)
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
