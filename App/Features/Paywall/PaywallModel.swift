import Foundation
import Observation

/// One plan tile, built from a RevenueCat package (see `Entitlements`) or by a preview mock.
struct PaywallPlan: Identifiable, Equatable, Sendable {
  enum Kind: Sendable { case annual, weekly }

  struct Trial: Equatable, Sendable {
    enum Unit: Sendable { case day, week, month, year }
    let value: Int
    let unit: Unit

    /// "3 days free", "1 week free".
    var badge: String {
      let noun = switch unit {
      case .day: value == 1 ? "day" : "days"
      case .week: value == 1 ? "week" : "weeks"
      case .month: value == 1 ? "month" : "months"
      case .year: value == 1 ? "year" : "years"
      }
      return "\(value) \(noun) free"
    }
  }

  /// The package identifier.
  let id: String
  let kind: Kind
  /// The store's localized price, e.g. "$29.99".
  let price: String
  /// Present only when the product has a free-trial intro offer the user can still get.
  let trial: Trial?

  var title: String { kind == .annual ? "Annual" : "Weekly" }
  var per: String { kind == .annual ? "year" : "week" }

  /// "then $29.99/year" with a trial, "$4.99/week" without.
  var priceLine: String { trial == nil ? "\(price)/\(per)" : "then \(price)/\(per)" }

  /// The renewal terms shown under the button (App Review guideline 3.1.2).
  var terms: String {
    if let trial { return "\(trial.badge), then \(price)/\(per). Cancel anytime in Settings." }
    return "\(price)/\(per), renews automatically. Cancel anytime in Settings."
  }
}

/// What the paywall needs from the purchase backend. `Entitlements` implements it with RevenueCat; previews use a mock.
@MainActor
protocol PurchaseProvider: AnyObject {
  /// The annual and weekly plans of the current offering, annual first.
  func paywallPlans() async throws -> [PaywallPlan]
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
  private(set) var plans: [PaywallPlan] = []
  var selectedID: String?
  private(set) var isWorking = false
  /// Shown in an alert.
  var message: String?
  /// Set once the user is Pro; the view closes itself.
  private(set) var didUnlock = false

  @ObservationIgnored private let provider: any PurchaseProvider

  init(provider: any PurchaseProvider) {
    self.provider = provider
  }

  var selected: PaywallPlan? { plans.first { $0.id == selectedID } }

  /// "Start free trial" when the selected plan has one, otherwise "Continue".
  var callToAction: String { selected?.trial != nil ? "Start free trial" : "Continue" }

  func load() async {
    phase = .loading
    do {
      let loaded = try await provider.paywallPlans()
      guard !loaded.isEmpty else {
        phase = .failed("No plans are available right now. Please try again later.")
        return
      }
      plans = loaded
      selectedID = (loaded.first { $0.kind == .annual } ?? loaded[0]).id
      phase = .ready
    } catch {
      phase = .failed("Plans couldn't load. Check your connection and try again.")
    }
  }

  func purchase() async {
    guard let plan = selected, !isWorking else { return }
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
        message = "No active subscription was found for this Apple Account."
      }
    } catch {
      message = error.localizedDescription
    }
  }
}
