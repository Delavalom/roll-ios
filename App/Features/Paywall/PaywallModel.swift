import Foundation
import Observation

/// Roll Pro: one non-consumable purchase (`roll_pro_lifetime`, RevenueCat package `$rc_lifetime`). No subscription.
/// Built from a RevenueCat package (see `Entitlements`) or by a preview mock.
struct PaywallPlan: Identifiable, Equatable, Sendable {
  /// The package identifier.
  let id: String
  /// The store's localized price, e.g. "$14.99".
  let price: String

  /// The purchase terms shown under the button: one payment, nothing renews, restorable.
  var terms: String {
    "One-time purchase of \(price). No subscription, nothing renews. Restore it anytime with the same Apple Account."
  }
}

/// What the paywall needs from the purchase backend. `Entitlements` implements it with RevenueCat; previews use a mock.
@MainActor
protocol PurchaseProvider: AnyObject {
  /// The one-time Roll Pro purchase of the current offering, or nil when the store has none to sell.
  func paywallPlan() async throws -> PaywallPlan?
  /// Returns true when the user is Pro afterwards; false if they cancelled the App Store sheet.
  func purchase(_ plan: PaywallPlan) async throws -> Bool
  /// Returns true when a restored purchase made the user Pro.
  func restorePurchases() async throws -> Bool
}

@Observable @MainActor
final class PaywallModel {
  enum Phase: Equatable {
    case loading
    case ready
    case failed(String)
  }

  private(set) var phase: Phase = .loading
  private(set) var plan: PaywallPlan?
  private(set) var isWorking = false
  /// Shown in an alert.
  var message: String?
  /// Set once the user is Pro; the view closes itself.
  private(set) var didUnlock = false

  @ObservationIgnored private let provider: any PurchaseProvider

  init(provider: any PurchaseProvider) {
    self.provider = provider
  }

  /// "Unlock for $14.99".
  var callToAction: String { plan.map { "Unlock for \($0.price)" } ?? "Unlock" }

  func load() async {
    phase = .loading
    do {
      guard let loaded = try await provider.paywallPlan() else {
        phase = .failed("Roll Pro isn't available right now. Please try again later.")
        return
      }
      plan = loaded
      phase = .ready
    } catch {
      phase = .failed("Roll Pro couldn't load. Check your connection and try again.")
    }
  }

  func purchase() async {
    guard let plan, !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      if try await provider.purchase(plan) { didUnlock = true }
    } catch {
      message = error.localizedDescription
    }
  }

  func restore() async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      if try await provider.restorePurchases() {
        didUnlock = true
      } else {
        message = "No Roll Pro purchase was found for this Apple Account."
      }
    } catch {
      message = error.localizedDescription
    }
  }
}
