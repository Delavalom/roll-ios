import XCTest

/// Ask Roll end to end on the seeded Roll-QA simulator: Home's cards, describe a pile, the answer (or "Nothing stood
/// out"), refine, swipe through with undo. Deletes nothing. With `ROLL_SHOTS=<folder>` in the test runner's environment
/// (`TEST_RUNNER_ROLL_SHOTS` for xcodebuild) each step is also saved there as a PNG, for design review. With
/// `ROLL_REAL_MODEL=1` it uses the real EmbeddingGemma; `ROLL_MODEL_PATH=<unpacked model folder>` points it at a local copy.
final class AskFlowTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testAskRefineSwipeAndUndo() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-onboardingComplete", "YES"]
    if ProcessInfo.processInfo.environment["ROLL_REAL_MODEL"] == nil { app.launchArguments += ["-UITestStubEmbedder"] }
    // Until the model is published, a DEBUG build loads a local copy (`EGCM_MODEL_PATH`, GemmaEmbedder.developerSource).
    if let path = ProcessInfo.processInfo.environment["ROLL_MODEL_PATH"] { app.launchEnvironment["EGCM_MODEL_PATH"] = path }
    app.launch()

    let allow = app.buttons["Allow Photos access"]
    if allow.waitForExistence(timeout: 5) { allow.tap() }
    allowPhotosAccessIfAsked()

    let card = app.buttons["home.card.screenshots"]
    XCTAssertTrue(card.waitForExistence(timeout: 60))
    sleep(4)
    shot("01-home")

    let composer = app.textFields["ask.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    let failed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS \"didn't finish\"")).firstMatch
    waitUntil(timeout: 1500) { composer.isEnabled || failed.exists }
    XCTAssertFalse(failed.exists, "the on-device model failed to load")
    // The real model then reads the library; give the index time to fill before asking.
    if ProcessInfo.processInfo.environment["ROLL_REAL_MODEL"] != nil {
      let reading = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Looking at' OR label BEGINSWITH 'Reading your library'")).firstMatch
      // The scan starts a moment after the model attaches: wait for it to show, then to finish.
      waitUntil(timeout: 120) { reading.exists }
      waitUntil(timeout: 1500) { !reading.exists }
      sleep(5)
    }
    composer.tap()
    composer.typeText("screenshots of group chats")
    sleep(2)
    shot("02-typing")
    composer.typeText("\n")

    let compared = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Compared '")).firstMatch
    XCTAssertTrue(compared.waitForExistence(timeout: 30), "the answer never arrived")
    sleep(3)
    shot("03-answer")

    let swipe = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Swipe through'")).firstMatch
    guard swipe.exists else {
      XCTAssertTrue(app.staticTexts["Nothing stood out"].exists)
      return
    }
    // "Biggest first" keeps every match (the seeded library is all from this year, so "Older than a year" empties it).
    app.buttons["Biggest first"].firstMatch.tap()
    sleep(3)
    shot("04-refine")

    let latest = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Swipe through'")).allElementsBoundByIndex.last
    if let latest, latest.exists, !latest.isHittable { app.swipeUp(); sleep(1) }
    let target = latest?.isHittable == true ? latest! : swipe
    XCTAssertTrue(target.exists && target.isHittable, "no reachable Swipe through button")
    target.tap()
    let queued = app.staticTexts["swipe.queued"]
    XCTAssertTrue(queued.waitForExistence(timeout: 30))
    sleep(2)
    shot("05-swipe")

    let keep = app.buttons["Keep"]
    waitUntil(timeout: 30) { keep.exists && keep.isEnabled }
    keep.tap()
    sleep(1)
    let top = app.descendants(matching: .any)["swipe.topCard"].firstMatch
    if top.exists { top.swipeLeft(velocity: .slow) }
    waitUntil(timeout: 10) { queued.label.hasPrefix("1 queued") }
    shot("06-swiped")

    app.buttons["Undo"].tap()
    waitUntil(timeout: 10) { queued.label.hasPrefix("0 queued") }
    XCTAssertTrue(queued.label.hasPrefix("0 queued"), queued.label)
    sleep(1)
    shot("07-undone")

    app.buttons["Back"].tap()
    XCTAssertTrue(app.buttons["New search"].waitForExistence(timeout: 10))
  }

  /// Every tab and the screens Home opens, in the brand (screenshots only; deletes nothing).
  @MainActor
  func testBrandTour() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-onboardingComplete", "YES", "-UITestStubEmbedder"]
    app.launch()
    let allow = app.buttons["Allow Photos access"]
    if allow.waitForExistence(timeout: 5) { allow.tap() }
    allowPhotosAccessIfAsked()
    XCTAssertTrue(app.buttons["home.card.screenshots"].waitForExistence(timeout: 60))
    sleep(3)

    for (kind, name) in [("duplicates", "t1-duplicates"), ("bigVideos", "t2-squish"), ("screenshots", "t3-pile")] {
      let card = app.buttons["home.card.\(kind)"]
      if !card.isHittable { app.swipeUp() }
      card.tap()
      sleep(3)
      shot(name)
      app.navigationBars.buttons.element(boundBy: 0).tap()
      sleep(1)
    }
    app.tabBars.buttons["Swipefiles"].tap()
    sleep(3)
    shot("t4-swipefiles")
    app.tabBars.buttons["Monitor"].tap()
    sleep(3)
    shot("t5-monitor")
  }

  /// Onboarding from a fresh start, the taste scan, then the paywall (screenshots only; buys nothing).
  @MainActor
  func testOnboardingAndPaywallTour() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-UITestStubEmbedder", "-UITestResetState"]
    app.launch()
    for page in 1...4 {
      let next = app.buttons["Continue"]
      XCTAssertTrue(next.waitForExistence(timeout: 15))
      waitUntil(timeout: 10) { next.isHittable && next.isEnabled }
      sleep(1)
      shot("o\(page)-onboarding")
      next.tap()
    }
    allowPhotosAccessIfAsked()
    sleep(2)
    shot("o5-scanning")
    let done = app.buttons["Continue"]
    waitUntil(timeout: 120) { done.exists && done.isEnabled }
    sleep(2)
    shot("o6-found")
    app.terminate()

    let paywall = XCUIApplication()
    paywall.launchArguments += ["-UITestOpen", "paywall", "-UITestSkipPaywall", "-UITestStubEmbedder"]
    paywall.launch()
    _ = paywall.buttons["Close"].waitForExistence(timeout: 30)
    sleep(4)
    shot("o7-paywall")
  }

  @MainActor
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

  @MainActor
  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
  }
}
