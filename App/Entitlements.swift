import Entitlements
import Foundation
import Observation
import RevenueCat

/// Pro status and purchases, backed by RevenueCat. The only file that imports RevenueCat: RollCore sees it through
/// `ProStatus`, the paywall through `PurchaseProvider`.
@Observable @MainActor
final class Entitlements {
  static let entitlementID = "pro"
  /// Info.plist key filled from `RC_PUBLIC_KEY` in the gitignored Team.xcconfig.
  static let apiKeyInfoKey = "RCPublicKey"
  /// Info.plist key filled from `RC_TEST_STORE_KEY` (RevenueCat Test Store). Empty in Release builds (project.yml).
  static let testStoreKeyInfoKey = "RCTestStoreKey"

  private(set) var isPro = false
  private(set) var isConfigured = false

  @ObservationIgnored private var packages: [String: Package] = [:]
  @ObservationIgnored private var updates: Task<Void, Never>?

  /// The public SDK key from Info.plist, or nil when Team.xcconfig left it empty. DEBUG builds launched with
  /// `-RCTestStore` use the RevenueCat Test Store key instead (and stay free-tier only if it's empty, never falling
  /// back to the real key).
  static func apiKeyFromInfoPlist(_ bundle: Bundle = .main,
                                  arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
    var infoKey = apiKeyInfoKey
    #if DEBUG
    if arguments.contains("-RCTestStore") { infoKey = testStoreKeyInfoKey }
    #endif
    guard let key = (bundle.object(forInfoDictionaryKey: infoKey) as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty, !key.hasPrefix("$(")
    else { return nil }
    return key
  }

  /// Configures RevenueCat once and follows customer info from then on. An empty key leaves the app free-tier only.
  func configure(apiKey: String?) {
    guard !isConfigured, let apiKey, !apiKey.isEmpty else { return }
    if !Purchases.isConfigured { Purchases.configure(withAPIKey: apiKey) }
    isConfigured = true
    updates = Task { [weak self] in
      for await info in Purchases.shared.customerInfoStream {
        self?.update(info)
      }
    }
  }

  private func update(_ info: CustomerInfo) {
    isPro = info.entitlements[Self.entitlementID]?.isActive == true
  }

  /// The annual and weekly packages of the current offering (`default`).
  func offerings() async throws -> (annual: Package?, weekly: Package?) {
    guard isConfigured else { throw EntitlementsError.notConfigured }
    let current = try await Purchases.shared.offerings().current
    return (current?.annual, current?.weekly)
  }

  /// Returns false when the user cancelled the App Store sheet.
  @discardableResult
  func purchase(_ package: Package) async throws -> Bool {
    guard isConfigured else { throw EntitlementsError.notConfigured }
    let result = try await Purchases.shared.purchase(package: package)
    update(result.customerInfo)
    return !result.userCancelled
  }

  func restore() async throws {
    guard isConfigured else { throw EntitlementsError.notConfigured }
    update(try await Purchases.shared.restorePurchases())
  }
}

enum EntitlementsError: LocalizedError {
  case notConfigured
  case planUnavailable

  var errorDescription: String? {
    switch self {
    case .notConfigured: "Purchases aren't available in this build."
    case .planUnavailable: "That plan isn't available right now."
    }
  }
}

// MARK: - RollCore

extension Entitlements: ProStatus {}

// MARK: - Paywall

extension Entitlements: PurchaseProvider {
  func paywallPlans() async throws -> [PaywallPlan] {
    let (annual, weekly) = try await offerings()
    var plans: [PaywallPlan] = []
    packages = [:]
    for (package, kind) in [(annual, PaywallPlan.Kind.annual), (weekly, .weekly)] {
      guard let package else { continue }
      packages[package.identifier] = package
      plans.append(PaywallPlan(id: package.identifier, kind: kind, price: package.storeProduct.localizedPriceString,
                               trial: await trial(for: package.storeProduct)))
    }
    return plans
  }

  /// The free trial, only when the product has one and the user can still get it.
  private func trial(for product: StoreProduct) async -> PaywallPlan.Trial? {
    guard let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial else { return nil }
    let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product)
    guard eligibility != .ineligible, eligibility != .noIntroOfferExists else { return nil }
    let period = intro.subscriptionPeriod
    let unit: PaywallPlan.Trial.Unit = switch period.unit {
    case .day: .day
    case .week: .week
    case .month: .month
    case .year: .year
    }
    return PaywallPlan.Trial(value: period.value, unit: unit)
  }

  func purchase(_ plan: PaywallPlan) async throws -> Bool {
    guard let package = packages[plan.id] else { throw EntitlementsError.planUnavailable }
    return try await purchase(package) && isPro
  }

  func restorePurchases() async throws -> Bool {
    try await restore()
    return isPro
  }
}
