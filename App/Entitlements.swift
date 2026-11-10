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

  /// The one-time Roll Pro package of the current offering (`default`): `$rc_lifetime`, or failing that the first
  /// non-subscription package, so a renamed package still sells.
  func lifetimePackage() async throws -> Package? {
    guard isConfigured else { throw EntitlementsError.notConfigured }
    let current = try await Purchases.shared.offerings().current
    return current?.lifetime
      ?? current?.availablePackages.first { $0.storeProduct.productCategory == .nonSubscription }
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
    case .planUnavailable: "Roll Pro isn't available right now."
    }
  }
}

// MARK: - RollCore

extension Entitlements: ProStatus {}

// MARK: - Paywall

extension Entitlements: PurchaseProvider {
  func paywallPlan() async throws -> PaywallPlan? {
    packages = [:]
    guard let package = try await lifetimePackage() else { return nil }
    packages[package.identifier] = package
    return PaywallPlan(id: package.identifier, price: package.storeProduct.localizedPriceString)
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
