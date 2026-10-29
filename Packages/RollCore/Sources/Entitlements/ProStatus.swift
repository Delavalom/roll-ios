/// Whether the user has Pro. The app adapts its RevenueCat-backed `Entitlements` to this, so RollCore
/// (and its tests) never import RevenueCat.
public protocol ProStatus: Sendable {
  var isPro: Bool { get async }
}
