import Overview
import SwiftUI

/// The Pro paywall (spec §10). Dismissible; the free tier keeps working without it.
struct PaywallView: View {
  @State private var model: PaywallModel
  /// The user's own number, when there is one worth leading with (`PaywallPitch`); nil keeps the generic header.
  private let pitch: PaywallPitch?
  private let onClose: () -> Void

  /// Apple's Standard EULA: Roll has no custom licence in App Store Connect, so this is the Terms of Use (EULA) that
  /// guideline 3.1.2 asks the paywall to link. Roll's own terms draft is docs/legal/terms.md.
  static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
  static let privacyURL = URL(string: "https://roll.delavalom.com/privacy")!

  init(provider: any PurchaseProvider, pitch: PaywallPitch? = nil, onClose: @escaping () -> Void) {
    _model = State(initialValue: PaywallModel(provider: provider))
    self.pitch = pitch
    self.onClose = onClose
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
        // The price first, so it's on screen above the button without scrolling; what Pro includes follows.
        SectionLabel("One-time purchase")
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
      Text(Self.headline(pitch))
        .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("paywall.headline")
        .padding(.top, Roll.Space.m)
      if let subline = pitch?.subline {
        Text(subline)
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("paywall.subline")
          .padding(.top, Roll.Space.xs)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// "Free about 3.2 GB on this iPhone" (the number the taste scan or Home showed), else the generic line. A
  /// non-breaking space keeps "about 3.2 GB" together when the headline wraps.
  static func headline(_ pitch: PaywallPitch?) -> String {
    guard let pitch else { return "Clean up your camera roll, privately" }
    return "Free \(ByteFormat.about(pitch.bytes).replacingOccurrences(of: " ", with: "\u{00A0}")) on this iPhone"
  }

  private var benefits: some View {
    RollGroup {
      RollRow(symbol: "text.magnifyingglass", title: "Describe it, Roll finds it",
              detail: "On-device AI finds screenshots, memes, blurry photos and more.")
      RollRow(symbol: "hand.draw", title: "Unlimited cleanups",
              detail: "Delete, move to albums and squish as much as you like. The first 50 are free.")
      RollRow(symbol: "lock.shield", title: "Never leaves your phone",
              detail: "Your photos are analyzed on your iPhone. Nothing about them leaves your phone.")
      RollRow(symbol: "checkmark.seal", title: "Pay once, keep it",
              detail: "No subscription. Restore Roll Pro anytime with the same Apple Account.")
    }
  }

  @ViewBuilder private var plansSection: some View {
    switch model.phase {
    case .loading:
      HStack(spacing: Roll.Space.xs) {
        RollMark(size: 22, busy: true)
        StatusLine(text: "Loading Roll Pro…")
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
      if let plan = model.plan { PriceCard(plan: plan) }
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
      .disabled(model.plan == nil || model.isWorking)

      // The purchase terms, readable, right under the button: one payment, nothing renews, restorable.
      if let plan = model.plan {
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

/// Roll Pro's one price: "Lifetime", the price and "once", on a white card with an ink border.
private struct PriceCard: View {
  let plan: PaywallPlan

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Roll.Space.s) {
      VStack(alignment: .leading, spacing: Roll.Space.xxs) {
        Text("Lifetime").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
        Text("Pay once. No subscription.")
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk2)
      }
      Spacer(minLength: 0)
      Text(plan.price).font(Roll.Typeface.title).foregroundStyle(.rollInk)
    }
    .padding(Roll.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.rollCard, in: RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous)
        .strokeBorder(Roll.Palette.ink, lineWidth: 1.5)
    }
    .rollShadow()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Lifetime, \(plan.price), pay once, no subscription")
    .accessibilityIdentifier("paywall.price")
  }
}

// MARK: - Previews

#if DEBUG
/// Offerings without the network, for previews.
@MainActor
final class MockPurchaseProvider: PurchaseProvider {
  var failsToLoad = false

  init(failsToLoad: Bool = false) {
    self.failsToLoad = failsToLoad
  }

  func paywallPlan() async throws -> PaywallPlan? {
    if failsToLoad { throw URLError(.notConnectedToInternet) }
    return PaywallPlan(id: "$rc_lifetime", price: "$14.99")
  }

  func purchase(_ plan: PaywallPlan) async throws -> Bool {
    try await Task.sleep(for: .seconds(1))
    return true
  }

  func restorePurchases() async throws -> Bool { false }
}

#Preview("Lifetime") {
  PaywallView(provider: MockPurchaseProvider()) {}
}

#Preview("After the taste scan") {
  PaywallView(provider: MockPurchaseProvider(),
              pitch: PaywallPitch.make(onDeviceBytes: 3_240_000_000,
                                       found: [FoundItem(kind: .duplicates, bytes: 1_900_000_000),
                                               FoundItem(kind: .screenshots, bytes: 900_000_000)])) {}
}

#Preview("Large text") {
  PaywallView(provider: MockPurchaseProvider()) {}
    .dynamicTypeSize(.accessibility2)
}

#Preview("Offline") {
  PaywallView(provider: MockPurchaseProvider(failsToLoad: true)) {}
}
#endif
