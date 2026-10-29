import SwiftUI

/// The Pro paywall (spec §10). Dismissible; the free tier keeps working without it.
struct PaywallView: View {
  @State private var model: PaywallModel
  private let onClose: () -> Void

  /// Apple's Standard EULA: Roll has no custom licence in App Store Connect, so this is the Terms of Use (EULA) that
  /// guideline 3.1.2 asks the paywall to link. Roll's own subscription terms draft is docs/legal/terms.md.
  static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
  static let privacyURL = URL(string: "https://roll.delavalom.com/privacy")!

  init(provider: any PurchaseProvider, onClose: @escaping () -> Void) {
    _model = State(initialValue: PaywallModel(provider: provider))
    self.onClose = onClose
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
        // Plans first, so they're on screen above the button without scrolling; what Pro includes follows.
        SectionLabel("Choose a plan")
          .padding(.top, Roll.Space.l)
          .padding(.bottom, Roll.Space.s)
        plansSection
        SectionLabel("Roll Pro includes")
          .padding(.top, Roll.Space.xl)
          .padding(.bottom, Roll.Space.s)
        benefits
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.top, 64)
      .padding(.bottom, Roll.Space.xl)
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom) { footer }
    .overlay(alignment: .topTrailing) { closeButton }
    .rollPage()
    .task { await model.load() }
    .onChange(of: model.didUnlock) { _, unlocked in if unlocked { onClose() } }
    .alert("Something went wrong", isPresented: messageShown) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.message ?? "")
    }
  }

  private var messageShown: Binding<Bool> {
    Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
  }

  // MARK: Parts

  private var closeButton: some View {
    Button("Close", systemImage: "xmark", action: onClose)
      .buttonStyle(.rollCircle)
      .padding(.trailing, Roll.Space.m)
      .padding(.top, Roll.Space.s)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Roll.Space.xs) {
        RollMark(size: Roll.Size.avatar)
        Text("Roll Pro").font(Roll.Typeface.headline).foregroundStyle(.rollInk2)
      }
      Text("Clean up your camera roll, privately")
        .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .padding(.top, Roll.Space.m)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var benefits: some View {
    RollGroup {
      RollRow(symbol: "text.magnifyingglass", title: "Describe it, Roll finds it",
              detail: "On-device AI finds screenshots, memes, blurry photos and more.")
      RollRow(symbol: "hand.draw", title: "Unlimited cleanups",
              detail: "Delete, move to albums and squish as much as you like. The first 50 are free.")
      RollRow(symbol: "lock.shield", title: "Never leaves your phone",
              detail: "Your photos are analyzed on your iPhone. Nothing about them leaves your phone.")
    }
  }

  @ViewBuilder private var plansSection: some View {
    switch model.phase {
    case .loading:
      HStack(spacing: Roll.Space.xs) {
        RollMark(size: 22, busy: true)
        StatusLine(text: "Loading plans…")
      }
      .frame(maxWidth: .infinity, minHeight: 120)
    case let .failed(text):
      VStack(spacing: Roll.Space.s) {
        Text(text)
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Button("Try Again") { Task { await model.load() } }
          .buttonStyle(.rollSecondary)
      }
      .frame(maxWidth: .infinity, minHeight: 120)
      .rollCard()
    case .ready:
      VStack(spacing: Roll.Space.s) {
        ForEach(model.plans) { plan in
          PlanTile(plan: plan, isSelected: plan.id == model.selectedID) { model.selectedID = plan.id }
        }
      }
      .animation(Roll.Motion.quick, value: model.selectedID)
    }
  }

  private var footer: some View {
    VStack(spacing: Roll.Space.xs) {
      Button {
        Task { await model.purchase() }
      } label: {
        ZStack {
          Text(model.callToAction).opacity(model.isWorking ? 0 : 1)
          if model.isWorking { ProgressView().tint(.rollOnInk) }
        }
      }
      .buttonStyle(.roll(.primary, fullWidth: true))
      .disabled(model.selected == nil || model.isWorking)

      // The renewal terms (App Review guideline 3.1.2): price, period and renewal, readable, right under the button.
      if let plan = model.selected {
        Text(plan.terms)
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Roll.Space.xxs)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: Roll.Space.s) { links(separated: true) }
        VStack(spacing: 0) { links(separated: false) }
      }
    }
    .padding(.horizontal, Roll.Space.page)
    .padding(.top, Roll.Space.s)
    .background(Roll.Palette.paper.ignoresSafeArea(edges: .bottom))
    .overlay(alignment: .top) {
      Rectangle().fill(.rollHairline).frame(height: Roll.hairlineWidth)
    }
  }

  @ViewBuilder private func links(separated: Bool) -> some View {
    let style = RollTextButtonStyle(color: .rollInk)
    Button("Restore Purchases") { Task { await model.restore() } }
      .buttonStyle(style)
      .disabled(model.isWorking)
    if separated { Text("·").foregroundStyle(.rollInk3).accessibilityHidden(true) }
    Link("Terms", destination: Self.termsURL).buttonStyle(style)
    if separated { Text("·").foregroundStyle(.rollInk3).accessibilityHidden(true) }
    Link("Privacy", destination: Self.privacyURL).buttonStyle(style)
  }
}

/// One plan as a selectable card: white with a hairline, or an ink 1.5 pt border once selected.
private struct PlanTile: View {
  let plan: PaywallPlan
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: Roll.Space.s) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.title2)
          .foregroundStyle(isSelected ? .rollInk : .rollInk3)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Roll.Space.xxs) {
          HStack(spacing: Roll.Space.xs) {
            Text(plan.title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
            if let trial = plan.trial {
              Text(trial.badge)
                .font(Roll.Typeface.label)
                .foregroundStyle(.rollOnInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.rollInk, in: Capsule())
            }
          }
          Text(plan.priceLine)
            .font(Roll.Typeface.callout)
            .foregroundStyle(.rollInk)
          if plan.kind == .annual {
            Text("Most popular")
              .font(Roll.Typeface.caption)
              .foregroundStyle(.rollInk2)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(Roll.Space.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.rollCard, in: RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous)
          .strokeBorder(isSelected ? Roll.Palette.ink : Roll.Palette.hairline,
                        lineWidth: isSelected ? 1.5 : Roll.hairlineWidth)
      }
      .rollShadow()
      .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    }
    .buttonStyle(PressScale())
    .accessibilityLabel(accessibilityText)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var accessibilityText: String {
    var parts = [plan.title]
    if let trial = plan.trial { parts.append(trial.badge) }
    parts.append(plan.priceLine)
    if plan.kind == .annual { parts.append("Most popular") }
    return parts.joined(separator: ", ")
  }
}

// MARK: - Previews

#if DEBUG
/// Offerings without the network, for previews.
@MainActor
final class MockPurchaseProvider: PurchaseProvider {
  var withTrial = true
  var failsToLoad = false

  init(withTrial: Bool = true, failsToLoad: Bool = false) {
    self.withTrial = withTrial
    self.failsToLoad = failsToLoad
  }

  func paywallPlans() async throws -> [PaywallPlan] {
    if failsToLoad { throw URLError(.notConnectedToInternet) }
    return [
      PaywallPlan(id: "$rc_annual", kind: .annual, price: "$29.99",
                  trial: withTrial ? PaywallPlan.Trial(value: 3, unit: .day) : nil),
      PaywallPlan(id: "$rc_weekly", kind: .weekly, price: "$4.99", trial: nil),
    ]
  }

  func purchase(_ plan: PaywallPlan) async throws -> Bool {
    try await Task.sleep(for: .seconds(1))
    return true
  }

  func restorePurchases() async throws -> Bool { false }
}

#Preview("Trial") {
  PaywallView(provider: MockPurchaseProvider()) {}
}

#Preview("No trial, large text") {
  PaywallView(provider: MockPurchaseProvider(withTrial: false)) {}
    .dynamicTypeSize(.accessibility2)
}

#Preview("Offline") {
  PaywallView(provider: MockPurchaseProvider(failsToLoad: true)) {}
}
#endif
