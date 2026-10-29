import XCTest

/// `-UITestOpen paywall` (DEBUG only) opens the paywall on launch; `-UITestSkipPaywall` keeps onboarding from
/// showing a second one underneath. Checks both plans, their prices, the annual trial and the legal links.
///
/// Under `xcodebuild test` the products come from the App Store sandbox, not Roll.storekit: the scheme's StoreKit
/// configuration applies only when Xcode runs the app (Cmd-R), and an `SKTestSession` in this UI-test runner
/// doesn't reach the app process. RevenueCat fetches the offering from its backend either way, so this needs the
/// network and `RC_PUBLIC_KEY` in Team.xcconfig; without them the plans can't load and the test is skipped.
final class PaywallTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testPaywallShowsBothPlansWithPricesAndTrial() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestOpen", "paywall", "-UITestSkipPaywall"]
    app.launch()

    let annual = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Annual'")).firstMatch
    if !annual.waitForExistence(timeout: 45) {
      if app.buttons["Try Again"].exists {
        throw XCTSkip("Plans couldn't load (no RC_PUBLIC_KEY in Team.xcconfig, or no network for RevenueCat).")
      }
      XCTFail("the annual plan never appeared")
    }
    XCTAssertEqual(annual.label, "Annual, 3 days free, then $29.99/year, Most popular")

    let weekly = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Weekly'")).firstMatch
    XCTAssertTrue(weekly.exists)
    XCTAssertEqual(weekly.label, "Weekly, $4.99/week")

    // The annual plan is preselected: its trial drives the button and the renewal terms.
    XCTAssertTrue(app.buttons["Start free trial"].exists)
    XCTAssertTrue(app.staticTexts["3 days free, then $29.99/year. Cancel anytime in Settings."].exists)
    XCTAssertTrue(app.links["Terms"].exists || app.buttons["Terms"].exists)
    XCTAssertTrue(app.links["Privacy"].exists || app.buttons["Privacy"].exists)

    // Weekly has no trial: selecting it switches the button and the terms.
    weekly.tap()
    XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["$4.99/week, renews automatically. Cancel anytime in Settings."].exists)
  }
}
