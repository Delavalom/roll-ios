import XCTest

/// The on-device AI's setup moment: the last onboarding step (one tap, then the two stages), and Home's setup card.
/// Needs the seeded Roll-QA simulator (`just seed-sim`). With the stub embedder the model attaches at once, so the
/// stages run straight to the library read. `TEST_RUNNER_ROLL_SHOTS=<folder>` also writes the screenshots there.
final class SetupFlowTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Onboarding ends on the setup screen: "Set up" starts it and shows the stages; Continue reaches Home.
  @MainActor
  func testSetupStepStartsSetupAndContinuesHome() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-UITestStubEmbedder", "-UITestResetState"]
    app.launch()
    for _ in 0..<2 {
      let next = app.buttons["Continue"]
      XCTAssertTrue(next.waitForExistence(timeout: 15))
      waitUntil(timeout: 10) { next.isHittable && next.isEnabled }
      next.tap()
    }
    allowPhotosAccessIfAsked()
    let scanDone = app.buttons["Continue"]
    waitUntil(timeout: 120) { scanDone.exists && scanDone.isEnabled }
    XCTAssertTrue(scanDone.isEnabled, "the taste scan didn't finish")
    scanDone.tap()

    let start = app.buttons["setup.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 15), "the setup step didn't follow the taste scan")
    XCTAssertTrue(app.staticTexts["Set up on-device AI"].exists)
    XCTAssertTrue(app.buttons["setup.notNow"].exists)
    sleep(1)
    shot("setup-before")
    start.tap()

    let next = app.buttons["setup.continue"]
    XCTAssertTrue(next.waitForExistence(timeout: 10), "Set up didn't start setup")
    XCTAssertFalse(app.buttons["setup.start"].exists)
    // The stub model attaches at once and the seeded library is small, so setup may already be done here.
    XCTAssertTrue(labelled("Reading your photos").exists || app.staticTexts["Roll is ready"].exists)
    XCTAssertTrue(app.buttons["setup.notify"].exists || app.staticTexts["Roll is ready"].exists)
    sleep(1)
    shot("setup-after")
    next.tap()

    XCTAssertTrue(app.staticTexts["What should we clear today?"].waitForExistence(timeout: 15), "Continue didn't reach Home")
  }

  /// Home's card while the model downloads: the stage, the bar and the one tap, which opens the setup screen.
  @MainActor
  func testHomeCardOpensSetup() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-UITestHoldModel", "-UITestResetState", "-onboardingComplete", "YES"]
    app.launch()
    // The held download keeps the card up (`-UITestHoldModel`: a third downloaded, never finishing).
    let action = app.buttons["setup.card.action"]
    XCTAssertTrue(action.waitForExistence(timeout: 20), "no setup card during the first read")
    XCTAssertEqual(action.label, "Set up")
    shot("home-card")
    action.tap()
    let done = app.buttons["setup.continue"]
    XCTAssertTrue(done.waitForExistence(timeout: 10), "the card's tap didn't open the setup screen")
    XCTAssertEqual(done.label, "Done")
    sleep(1)
    shot("home-card-sheet")
    done.tap()
    XCTAssertTrue(app.staticTexts["What should we clear today?"].waitForExistence(timeout: 10))
  }

  private func labelled(_ text: String) -> XCUIElement {
    XCUIApplication().descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  private func shot(_ name: String) {
    let png = XCUIScreen.main.screenshot().pngRepresentation
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let folder = ProcessInfo.processInfo.environment["ROLL_SHOTS"] {
      try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
  }

  /// The Photos permission prompt belongs to SpringBoard.
  @MainActor
  private func allowPhotosAccessIfAsked() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.alerts.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] 'Full Access' OR label CONTAINS[c] 'All Photos' OR label ==[c] 'Allow'")).firstMatch
    if allow.waitForExistence(timeout: 10) { allow.tap() }
  }

  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
  }
}
