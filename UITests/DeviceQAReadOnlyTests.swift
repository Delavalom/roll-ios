import XCTest

/// Part 1: read-only metrics on the whole library. The app runs with `-QAMetrics` and no `-QAAlbum`, so every change
/// is refused (`QAReadOnlyGate`) even if a tap went wrong; these tests never tap Apply or Squish.
///
/// Classes are named so one `xcodebuild test-without-building` runs them in order (XCTest sorts by name): Part 1
/// (`DeviceQA1`), the destructive album cases (`DeviceQA2`), then the read-only extras (`DeviceQA3`), with no gaps
/// in which the phone could lock.
final class DeviceQA1Part1Tests: DeviceQABase {
  static let indexingBudget: TimeInterval = 15 * 60

  @MainActor
  func testP1FullLibraryMetrics() throws {
    try requireDeviceQA()
    let app = XCUIApplication()
    // The reset is the point of P1 (a first launch: onboarding, taste scan, the full index from nothing). It can't lose
    // an unfinished squish: with open journal rows it keeps the journal (`AppDatabase.resetForUITests`).
    app.launchArguments += ["-UITestResetState", "-QAMetrics"]
    app.launch()
    onboard(app, prefix: "p1-01")

    // The onboarding paywall (real RevenueCat offering; prices may be missing until the sandbox is set up).
    let close = app.buttons["Close"]
    if close.waitForExistence(timeout: 20) {
      sleep(8)
      shot("p1-02-paywall-onboarding")
      close.tap()
    }

    // Home while the full index runs, then until it finishes or the budget runs out.
    let home = app.navigationBars["Roll"]
    XCTAssertTrue(home.waitForExistence(timeout: 30))
    sleep(5)
    shot("p1-03-home-indexing-start")
    let done = NSPredicate(format: "label CONTAINS 'photos and videos'")
    let start = Date()
    var lastShot = Date()
    var finished = false
    while Date().timeIntervalSince(start) < Self.indexingBudget {
      if app.staticTexts.containing(done).firstMatch.exists,
         !app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Looking at'")).firstMatch.exists {
        finished = true
        break
      }
      if Date().timeIntervalSince(lastShot) > 300 {
        shot("p1-03-home-indexing-\(Int(Date().timeIntervalSince(start) / 60))min")
        lastShot = Date()
      }
      RunLoop.current.run(until: Date().addingTimeInterval(10))
    }
    attachText("p1-indexing-outcome", finished ? "finished after \(Int(Date().timeIntervalSince(start))) s"
                                                : "still indexing after \(Int(Self.indexingBudget)) s")
    sleep(8)  // Home rescans at most every 5 s
    shot("p1-04-home")
    app.swipeUp()
    shot("p1-04-home-scrolled")
    app.swipeDown()

    for (kind, name) in [("duplicates", "duplicates"), ("similarShots", "similar"), ("screenshots", "screenshots"),
                         ("blurry", "blurry"), ("bigVideos", "squish")] {
      let card = app.buttons["home.card.\(kind)"]
      reveal(card, in: app)
      guard card.waitForExistence(timeout: 10) else { attachText("p1-missing-\(name)", "no card"); continue }
      card.tap()
      sleep(6)
      shot("p1-05-\(name)")
      if kind == "bigVideos" {
        let refused = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Not squishable yet'")).firstMatch
        reveal(refused, in: app)
        if refused.exists {
          refused.tap()
          sleep(2)
          shot("p1-05-squish-not-squishable")
        }
      }
      if kind == "duplicates" || kind == "similarShots" {
        let group = app.buttons["duplicates.group"].firstMatch
        if group.exists, group.isHittable {
          let list = app.navigationBars.firstMatch.identifier
          group.tap()
          sleep(3)
          shot("p1-05-\(name)-group")
          // Back only if the tap opened something: a missed tap left the list up, and a second back from Home failed
          // the run (2026-10-25).
          if app.navigationBars.firstMatch.identifier != list
            || app.descendants(matching: .any)["swipe.topCard"].firstMatch.exists {
            back(app)
          } else {
            attachText("p1-05-\(name)-group-not-opened", "the tap on the first group didn't open it")
          }
        }
      }
      back(app)
      app.swipeDown()
    }

    app.tabBars.buttons["Swipefiles"].tap()
    sleep(3)
    shot("p1-06-swipefiles")
    app.tabBars.buttons["Monitor"].tap()
    sleep(8)
    shot("p1-07-monitor")
    app.swipeUp()
    sleep(2)
    shot("p1-07-monitor-scrolled")
    app.tabBars.buttons["Home"].tap()
    // Keep the app in the foreground a little longer so the last metrics land.
    sleep(20)
  }
}

/// Read-only extras after the album cases: the paywall and large text, the RevenueCat Test Store purchase, and the
/// thumbnail probe.
final class DeviceQA3ExtrasTests: DeviceQABase {

  /// The paywall through `-UITestOpen paywall`, then the main screens at an accessibility text size.
  @MainActor
  func testP2PaywallAndLargeText() throws {
    try requireDeviceQA()
    let app = XCUIApplication()
    app.launchArguments += ["-QAMetrics", "-UITestOpen", "paywall", "-UITestSkipPaywall"]
    app.launch()
    let close = app.buttons["Close"]
    XCTAssertTrue(close.waitForExistence(timeout: 30))
    sleep(10)
    shot("p1-08-paywall")
    app.swipeUp()
    shot("p1-08-paywall-scrolled")
    close.tap()
    app.terminate()

    for size in ["UICTContentSizeCategoryAccessibilityL", "UICTContentSizeCategoryXXXL"] {
      let tag = size == "UICTContentSizeCategoryXXXL" ? "xxxl" : "axl"
      let big = XCUIApplication()
      big.launchArguments += ["-QAMetrics", "-UIPreferredContentSizeCategoryName", size]
      big.launch()
      XCTAssertTrue(big.navigationBars["Roll"].waitForExistence(timeout: 30))
      sleep(8)
      shot("p1-09-\(tag)-home")
      big.swipeUp()
      shot("p1-09-\(tag)-home-scrolled")
      big.swipeDown()
      let squish = big.buttons["home.card.bigVideos"]
      reveal(squish, in: big)
      if squish.exists {
        squish.tap()
        sleep(5)
        shot("p1-09-\(tag)-squish")
        back(big)
      }
      big.tabBars.buttons["Monitor"].tap()
      sleep(5)
      shot("p1-09-\(tag)-monitor")
      big.terminate()
      let paywall = XCUIApplication()
      paywall.launchArguments += ["-QAMetrics", "-UIPreferredContentSizeCategoryName", size, "-UITestOpen", "paywall",
                                  "-UITestSkipPaywall"]
      paywall.launch()
      if paywall.buttons["Close"].waitForExistence(timeout: 30) {
        sleep(8)
        shot("p1-09-\(tag)-paywall")
        paywall.swipeUp()
        shot("p1-09-\(tag)-paywall-scrolled")
      }
      paywall.terminate()
    }
  }

  /// RevenueCat Test Store (`-RCTestStore`): with the free quota used up (`-QAExhaustFreeQuota`, Roll's own counter
  /// only), queue one screenshot, see the plan blocked, buy Roll Pro (one-time) through the Test Store sheet, and check the plan
  /// becomes appliable. Nothing is applied (and the read-only gate would refuse it). Then Restore.
  @MainActor
  func testP3TestStorePurchaseUnlocksPro() throws {
    try requireDeviceQA()
    let app = XCUIApplication()
    app.launchArguments += ["-QAMetrics", "-RCTestStore", "-QAExhaustFreeQuota", "-UITestSkipPaywall"]
    app.launch()
    let card = app.buttons["home.card.screenshots"]
    XCTAssertTrue(card.waitForExistence(timeout: 60))
    sleep(5)
    card.tap()
    let top = app.descendants(matching: .any)["swipe.topCard"].firstMatch
    XCTAssertTrue(top.waitForExistence(timeout: 30), "no screenshot to queue")
    let queued = app.staticTexts["swipe.queued"]
    func queuedCount() -> Int { Int(queued.label.prefix { $0.isNumber }) ?? -1 }
    let before = queuedCount()
    top.swipeLeft(velocity: .fast)
    XCTAssertTrue(waitUntil(timeout: 10) { queuedCount() == before + 1 }, queued.label)
    app.buttons["Review & apply"].tap()

    let blocked = app.buttons.containing(NSPredicate(format: "label CONTAINS 'need Roll Pro' OR label CONTAINS 'needs Roll Pro'"))
      .firstMatch
    XCTAssertTrue(blocked.waitForExistence(timeout: 15), "the plan should be blocked by the used-up free quota")
    shot("p3-01-plan-blocked-by-quota")
    blocked.tap()

    let cta = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Unlock for'")).firstMatch
    guard cta.waitForExistence(timeout: 45) else {
      shot("p3-02-paywall-no-plans")
      XCTFail("the Test Store Roll Pro product didn't load")
      return
    }
    shot("p3-02-paywall-test-store")
    attachText("p3-plan-labels", app.buttons.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
    cta.tap()

    // RevenueCat's Test Store purchase sheet: tap its success option.
    let success = NSPredicate(format: "label CONTAINS[c] 'valid purchase' OR label CONTAINS[c] 'successful' OR label CONTAINS[c] 'success'")
    let option = app.descendants(matching: .any).matching(success).firstMatch
    if !option.waitForExistence(timeout: 30) {
      shot("p3-03-test-store-sheet-unknown")
      attachText("p3-test-store-sheet", app.debugDescription)
      let alertOption = app.alerts.buttons.matching(success).firstMatch
      XCTAssertTrue(alertOption.exists, "couldn't find the Test Store success option")
      alertOption.tap()
    } else {
      shot("p3-03-test-store-sheet")
      attachText("p3-test-store-sheet", app.debugDescription)
      option.tap()
    }

    // Pro unlocks: the paywall closes and the plan reloads without the quota block.
    // "Delete N items", or "Apply" when the plan is only album moves (a delete can be held back to keep a duplicate set).
    let apply = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete ' OR label == 'Apply'")).firstMatch
    XCTAssertTrue(apply.waitForExistence(timeout: 60), "the paywall didn't close after the purchase")
    XCTAssertTrue(waitUntil(timeout: 20) { apply.isEnabled && !blocked.exists }, "the plan is still blocked")
    shot("p3-04-plan-appliable-after-purchase")
    app.buttons["Cancel"].tap()  // never apply
    let undo = app.buttons["Undo"]
    if undo.waitForExistence(timeout: 10) { undo.tap() }
    app.terminate()

    // Restore on the paywall.
    let again = XCUIApplication()
    again.launchArguments += ["-QAMetrics", "-RCTestStore", "-UITestOpen", "paywall", "-UITestSkipPaywall"]
    again.launch()
    let restore = again.buttons["Restore Purchases"]
    reveal(restore, in: again)
    XCTAssertTrue(restore.waitForExistence(timeout: 30))
    shot("p3-05-paywall-before-restore")
    restore.tap()
    let closed = waitUntil(timeout: 30) { !again.buttons["Restore Purchases"].exists }
    shot("p3-06-after-restore")
    attachText("p3-restore-outcome", closed ? "paywall closed (Pro restored)"
                                            : "paywall still open: " + again.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
    XCTAssertTrue(closed, "Restore didn't unlock Pro")
  }
}

extension DeviceQA3ExtrasTests {
  /// Thumbnail probe (`-QAThumbProbe`, read-only): which preview sizes the library keeps locally and the Vision time per
  /// image. It starts 90 s after launch; the app stays in the foreground until it's done.
  @MainActor
  func testP4ThumbnailProbe() throws {
    try requireDeviceQA()
    let app = XCUIApplication()
    app.launchArguments += ["-QAMetrics", "-QAThumbProbe", "-UITestSkipPaywall"]
    app.launch()
    XCTAssertTrue(app.navigationBars["Roll"].waitForExistence(timeout: 60))
    for minute in 1...8 {
      sleep(60)
      if minute == 4 { shot("p4-thumb-probe-running") }
    }
    shot("p4-thumb-probe-end")
  }
}
