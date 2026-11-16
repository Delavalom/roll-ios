import XCTest

/// Find on the seeded Roll-QA simulator: ask, Make album, the selection grid, Create through the commit path, and the
/// album-created screen. Adds the picked photos to an album in the simulator's library (nothing is deleted). With the
/// stub embedder the shipping config refuses every query ("Nothing clearly matched", the closest 12), so the first test
/// makes the album from those; the tour passes `-UITestNoRefusal` (DEBUG) to show a found answer with event sections.
/// With `ROLL_SHOTS=<folder>` (`TEST_RUNNER_ROLL_SHOTS` for xcodebuild) each step is also saved there as a PNG.
final class FindFlowTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// search → Make album → album created.
  @MainActor
  func testSearchMakeAlbumCreated() throws {
    let app = launch()
    ask(app, "screenshots")
    shot("f1-answer")

    let make = app.buttons["ask.makeAlbum"]
    XCTAssertTrue(make.waitForExistence(timeout: 10), "no Make album on the answer")
    reveal(make, in: app)
    make.tap()
    createAlbum(app)
  }

  /// A found answer with sections, the section's album grid and the created screen, and the memory video sheet.
  @MainActor
  func testFindTour() throws {
    let app = launch(extra: ["-UITestNoRefusal"])
    ask(app, "screenshots")
    shot("t1-sections")
    let section = app.buttons["section.makeAlbum"].firstMatch
    let make = section.waitForExistence(timeout: 5) ? section : app.buttons["ask.makeAlbum"]
    XCTAssertTrue(make.waitForExistence(timeout: 10))
    reveal(make, in: app)
    make.tap()
    createAlbum(app, shots: ("t2-make-album", "t3-created"))
    let keep = app.buttons["album.keepUpdated"]
    if keep.exists {
      keep.tap()
      let kept = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Kept up to date'")).firstMatch
      XCTAssertTrue(kept.waitForExistence(timeout: 10), "the living album wasn't saved")
      shot("t3b-kept-updated")
    }
    let video = app.buttons["Make a video"]
    if video.waitForExistence(timeout: 3) {
      video.tap()
      sleep(4)
      shot("t4-video-rendering")
      let done = app.buttons["Done"]
      waitUntil(timeout: 180) { done.exists }
      sleep(2)
      shot("t5-video-ready")
      if done.exists { done.tap() }
    }
  }

  // MARK: Steps

  @MainActor
  private func launch(extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-onboardingComplete", "YES", "-UITestStubEmbedder"] + extra
    app.launch()
    let allow = app.buttons["Allow Photos access"]
    if allow.waitForExistence(timeout: 5) { allow.tap() }
    allowPhotosAccessIfAsked()
    XCTAssertTrue(app.buttons["home.card.screenshots"].waitForExistence(timeout: 60))
    return app
  }

  @MainActor
  private func ask(_ app: XCUIApplication, _ text: String) {
    let composer = app.textFields["ask.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    waitUntil(timeout: 120) { composer.isEnabled }
    XCTAssertTrue(composer.isEnabled, "the stub embedder never attached")
    composer.tap()
    composer.typeText(text + "\n")
    let compared = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Compared '")).firstMatch
    XCTAssertTrue(compared.waitForExistence(timeout: 30), "the answer never arrived")
    sleep(2)
  }

  /// On the Make album grid: select everything if nothing is preselected, Create, and wait for the created screen.
  @MainActor
  private func createAlbum(_ app: XCUIApplication, shots: (String, String) = ("f2-make-album", "f3-created")) {
    let create = app.buttons["album.create"]
    XCTAssertTrue(create.waitForExistence(timeout: 10), "the Make album grid didn't open")
    let all = app.buttons["album.toggleAll"]
    if !create.isEnabled, all.exists, all.label == "Select all" { all.tap() }
    waitUntil(timeout: 5) { create.isEnabled }
    XCTAssertTrue(create.isEnabled, "nothing to add: \(app.staticTexts["album.count"].label)")
    sleep(1)
    shot(shots.0)
    create.tap()

    let created = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Added ' OR label BEGINSWITH 'Already in'")).firstMatch
    XCTAssertTrue(created.waitForExistence(timeout: 30),
                  app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Roll Pro'")).firstMatch.exists
                    ? "blocked by the free quota" : "the album wasn't created")
    XCTAssertTrue(app.buttons["album.done"].exists)
    sleep(1)
    shot(shots.1)
  }

  @MainActor
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<4 where !element.isHittable { app.swipeUp() }
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
