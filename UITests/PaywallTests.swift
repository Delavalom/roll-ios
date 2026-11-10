import XCTest

/// `-UITestOpen paywall` (DEBUG only) opens the paywall on launch; `-UITestSkipPaywall` keeps onboarding from
/// showing a second one underneath. Checks the one-time Roll Pro price, the button, the terms and the legal links.
///
/// Under `xcodebuild test` the products come from the App Store sandbox, not Roll.storekit: the scheme's StoreKit
/// configuration applies only when Xcode runs the app (Cmd-R), and an `SKTestSession` in this UI-test runner
/// doesn't reach the app process. RevenueCat fetches the offering from its backend either way, so this needs the
/// network and `RC_PUBLIC_KEY` in Team.xcconfig; without them the price can't load and the test is skipped.
final class PaywallTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testPaywallShowsOneTimePurchase() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestOpen", "paywall", "-UITestSkipPaywall"]
    app.launch()

    let price = app.descendants(matching: .any)["paywall.price"].firstMatch
    if !price.waitForExistence(timeout: 45) {
      if app.buttons["Try Again"].exists {
        throw XCTSkip("Roll Pro couldn't load (no RC_PUBLIC_KEY in Team.xcconfig, or no network for RevenueCat).")
      }
      XCTFail("the Roll Pro price never appeared")
    }
    XCTAssertEqual(price.label, "Lifetime, $14.99, pay once, no subscription")
    XCTAssertTrue(app.buttons["Unlock for $14.99"].exists)
    XCTAssertTrue(app.staticTexts[
      "One-time purchase of $14.99. No subscription, nothing renews. Restore it anytime with the same Apple Account."
    ].exists)
    XCTAssertTrue(app.buttons["Restore Purchases"].exists)
    XCTAssertTrue(app.links["Terms"].exists || app.buttons["Terms"].exists)
    XCTAssertTrue(app.links["Privacy"].exists || app.buttons["Privacy"].exists)
  }
}
