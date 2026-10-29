import XCTest

/// Task 14's seeded smoke test: onboarding → taste scan → Screenshots pile → swipe left ×5 → Review & apply → Apply →
/// accept the system delete confirmation → Home's Screenshots count drops by 5.
///
/// Needs the seeded Roll-QA simulator (`just seed-sim`: Photos access granted, 12 screenshots, a few videos). The
/// launch arguments are honoured in DEBUG builds only (`AppModel.live()`): the stub embedder, no paywall, and a fresh
/// start (Roll's database and onboarding flag are removed, the photo library is not). Each run deletes 5 screenshots
/// (into Recently Deleted), so re-seed after two runs.
final class SmokeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunches() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
  }

  @MainActor
  func testSeededCleanupDeletesFiveScreenshots() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-UITestStubEmbedder", "-UITestResetState"]
    app.launch()

    // Onboarding: three value pages, then the permission step. seed_sim.sh grants Photos access, but if iOS asks
    // anyway (the grant can be lost when the app is reinstalled), allow full access.
    for _ in 0..<4 {
      let next = app.buttons["Continue"]
      XCTAssertTrue(next.waitForExistence(timeout: 15))
      waitUntil(timeout: 10) { next.isHittable && next.isEnabled }
      next.tap()
    }
    allowPhotosAccessIfAsked()

    // Taste scan: wait for the numbers, then continue (the paywall is skipped).
    let found = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'You can free about'")).firstMatch
    XCTAssertTrue(found.waitForExistence(timeout: 120), "the taste scan didn't finish")
    let continueButton = app.buttons["Continue"]
    waitUntil(timeout: 10) { continueButton.isEnabled }
    continueButton.tap()

    // Home: the Screenshots card, once the scan's numbers are in.
    let card = app.buttons["home.card.screenshots"]
    XCTAssertTrue(card.waitForExistence(timeout: 30))
    var before = 0
    waitUntil(timeout: 30) {
      before = Self.screenshotCount(in: card.label)
      return before >= 5
    }
    XCTAssertGreaterThanOrEqual(before, 5, "the seeded library needs at least 5 screenshots (\(card.label))")
    card.tap()

    // Swipe the top card left five times (the pile's action: delete).
    let queued = app.staticTexts["swipe.queued"]
    XCTAssertTrue(queued.waitForExistence(timeout: 30))
    for swiped in 1...5 {
      let top = app.descendants(matching: .any)["swipe.topCard"].firstMatch
      XCTAssertTrue(top.waitForExistence(timeout: 30), "no card to swipe (\(swiped - 1) swiped)")
      // Keep is enabled only while the top card's photo is on screen (CardGate.decide); before that a swipe snaps back.
      let keep = app.buttons["Keep"]
      waitUntil(timeout: 30) { keep.exists && keep.isEnabled }
      XCTAssertTrue(keep.exists && keep.isEnabled, "the top card never became decidable (\(swiped - 1) swiped)")
      top.swipeLeft(velocity: .fast)
      waitUntil(timeout: 10) { queued.label.hasPrefix("\(swiped) queued") }
      XCTAssertTrue(queued.label.hasPrefix("\(swiped) queued"), "swipe \(swiped) wasn't queued: \(queued.label)")
    }

    app.buttons["Review & apply"].tap()
    let apply = app.buttons["Delete 5 items"]
    XCTAssertTrue(apply.waitForExistence(timeout: 15))
    waitUntil(timeout: 10) { apply.isEnabled }
    apply.tap()

    // iOS asks before deleting. The alert belongs to the system, not to Roll.
    try acceptDeleteConfirmation(app)

    let deleted = app.staticTexts["Deleted 5"]
    XCTAssertTrue(deleted.waitForExistence(timeout: 30), "the sheet didn't report the delete")
    app.buttons["Done"].tap()
    app.navigationBars.buttons.element(boundBy: 0).tap()

    // Home recounts after the commit (scans are throttled to one every 5 s).
    XCTAssertTrue(card.waitForExistence(timeout: 15))
    waitUntil(timeout: 30) { Self.screenshotCount(in: card.label) == before - 5 }
    XCTAssertEqual(Self.screenshotCount(in: card.label), before - 5, card.label)
  }

  /// The Photos permission prompt belongs to SpringBoard.
  @MainActor
  private func allowPhotosAccessIfAsked() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.alerts.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] 'Full Access' OR label CONTAINS[c] 'All Photos' OR label ==[c] 'Allow'")).firstMatch
    // On a freshly erased simulator the prompt can take longer than 5 s to appear.
    if allow.waitForExistence(timeout: 15) {
      allow.tap()
    } else if springboard.alerts.firstMatch.exists {
      XCTFail("unexpected system alert: \(springboard.alerts.firstMatch.buttons.allElementsBoundByIndex.map(\.label))")
    }
  }

  /// Taps "Delete" on the system's delete confirmation. It is shown by a system process, so it's looked up in
  /// SpringBoard first; an interruption monitor covers the case where it is attached to Roll instead.
  @MainActor
  private func acceptDeleteConfirmation(_ app: XCUIApplication) throws {
    let monitor = addUIInterruptionMonitor(withDescription: "Delete confirmation") { alert in
      let delete = alert.buttons["Delete"]
      guard delete.exists else { return false }
      delete.tap()
      return true
    }
    defer { removeUIInterruptionMonitor(monitor) }

    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
        let delete = alert.buttons["Delete"]
        if delete.exists {
          delete.tap()
          return
        }
      }
      if app.staticTexts["Deleted 5"].exists { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    XCTFail("the delete confirmation never appeared")
  }

  /// "Screenshots, 12 screenshots, about 40 MB" → 12.
  private static func screenshotCount(in label: String) -> Int {
    guard let match = label.firstMatch(of: /([\d,]+) screenshots?/) else { return -1 }
    return Int(match.1.replacingOccurrences(of: ",", with: "")) ?? -1
  }

  @MainActor
  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
  }
}
