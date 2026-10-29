import XCTest

/// Device QA on a real iPhone (docs/qa/device-2026-10-23.md). Skipped unless the runner gets `ROLL_DEVICE_QA=1`
/// (`TEST_RUNNER_ROLL_DEVICE_QA=1 xcodebuild test ...`), so `just uitest` on the simulator never runs them.
///
/// Screenshots are XCTest attachments (`p1-…`, `d…-…`); export them from the xcresult into artifacts/qa/ (gitignored:
/// they show the user's photos). Metrics come from the app (`Documents/qa/metrics.jsonl`).
class DeviceQABase: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func requireDeviceQA() throws {
    guard ProcessInfo.processInfo.environment["ROLL_DEVICE_QA"] == "1" else {
      throw XCTSkip("device QA runs only with TEST_RUNNER_ROLL_DEVICE_QA=1")
    }
  }

  @MainActor
  func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func attachText(_ name: String, _ text: String) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(poll))
    }
    return condition()
  }

  /// Onboarding after a reset: three value pages, the permission step (allowing full access if iOS asks), the taste
  /// scan (screenshot `<prefix>-taste-scan`), then Continue. Leaves the app on the paywall (unless skipped) or Home.
  @MainActor
  func onboard(_ app: XCUIApplication, prefix: String, tasteScanTimeout: TimeInterval = 900) {
    for _ in 0..<4 {
      let next = app.buttons["Continue"]
      XCTAssertTrue(next.waitForExistence(timeout: 20), "onboarding Continue missing")
      _ = waitUntil(timeout: 10) { next.isHittable && next.isEnabled }
      next.tap()
    }
    allowPhotosAccessIfAsked()
    let scanning = app.staticTexts["Looking at your newest photos"]
    if scanning.waitForExistence(timeout: 10) { shot("\(prefix)-taste-scan-running") }
    // The taste scan's header: on-device bytes, or (an iCloud library) "Your library is mostly in iCloud".
    let found = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'You can free about' OR "
      + "label BEGINSWITH 'Nothing confirmed on this iPhone' OR label BEGINSWITH 'Nothing big to free'")).firstMatch
    XCTAssertTrue(found.waitForExistence(timeout: tasteScanTimeout), "the taste scan didn't finish")
    sleep(2)
    shot("\(prefix)-taste-scan-result")
    // If something brought another app forward, come back before tapping (a missed tap leaves onboarding unfinished,
    // and every later launch would open on it).
    if app.state != .runningForeground { app.activate() }
    let continueButton = app.buttons["Continue"]
    _ = waitUntil(timeout: 15) { continueButton.isEnabled && continueButton.isHittable }
    continueButton.tap()
    let leftScan = waitUntil(timeout: 10) { !found.exists }
    if !leftScan, continueButton.exists {
      if app.state != .runningForeground { app.activate() }
      continueButton.tap()
    }
  }

  @MainActor
  func allowPhotosAccessIfAsked() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.alerts.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] 'Full Access' OR label CONTAINS[c] 'All Photos' OR label ==[c] 'Allow'")).firstMatch
    if allow.waitForExistence(timeout: 6) { allow.tap() }
  }

  /// The alert's button titled `title`, whichever apostrophe iOS uses: the delete prompt says "Don’t Allow" (U+2019),
  /// so a lookup by "Don't Allow" never matched and D4/D5 waited out the prompt (2026-10-24).
  @MainActor
  func alertButton(_ alert: XCUIElement, _ title: String) -> XCUIElement {
    let curly = title.replacingOccurrences(of: "'", with: "\u{2019}")
    return alert.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", title, curly)).firstMatch
  }

  /// Taps a button on a system alert (SpringBoard first, then the app). Returns the alert's text when found.
  @MainActor
  func tapSystemAlert(_ app: XCUIApplication, button: String, timeout: TimeInterval) -> String? {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
        let target = alertButton(alert, button)
        if target.exists {
          let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
          shot("system-alert-\(button.lowercased().replacingOccurrences(of: " ", with: "-"))")
          target.tap()
          return text
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return nil
  }

  /// Goes back one screen and makes sure it left a swipe pile: a scroll gesture on a card stack is a swipe (up queues
  /// "add to album"), so later scrolling must never run there.
  /// Checks the screen really changed (D1, 2026-10-24: a back tap on a scrolled Squish list didn't register, and the
  /// next step swiped through Squish looking for a Home card); falls back to the edge swipe.
  @MainActor
  func back(_ app: XCUIApplication) {
    let from = app.navigationBars.firstMatch.identifier
    for attempt in 0..<3 {
      let button = app.navigationBars.buttons.element(boundBy: 0)
      if attempt < 2, button.exists, button.isHittable {
        button.tap()
      } else {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
          .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
      }
      sleep(1)
      let left = from.isEmpty || !app.navigationBars[from].exists
      if left, !app.descendants(matching: .any)["swipe.topCard"].firstMatch.exists { return }
    }
    XCTFail("couldn't go back from \(from.isEmpty ? "this screen" : from)")
  }

  /// Scrolls the list until `element` is hittable (up to 6 swipes).
  @MainActor
  func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
  }
}
