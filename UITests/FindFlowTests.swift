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

  /// Swipe to select on the Make album grid, as in Photos: a sideways drag selects every photo it passes, a drag from a
  /// selected photo deselects, and an up/down swipe still scrolls. Creates nothing.
  @MainActor
  func testDragSelectsAcrossTheGrid() throws {
    let app = launch(extra: ["-UITestOpen", "album"], home: false)
    let all = app.buttons["album.toggleAll"]
    let count = app.staticTexts["album.count"]
    XCTAssertTrue(all.waitForExistence(timeout: 20), "the Make album grid didn't open")
    XCTAssertTrue(count.label.hasPrefix("0 of"), count.label)

    func cell(_ i: Int) -> XCUICoordinate {
      app.descendants(matching: .any)["album.cell.\(i)"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
    // The first two rows on screen (the grid is lazy: cells below the fold don't exist yet).
    let sixth = app.descendants(matching: .any)["album.cell.5"]
    for _ in 0..<6 where !(sixth.exists && sixth.isHittable) {
      let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
      mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 0, dy: -150)))
      sleep(1)
    }
    XCTAssertTrue(app.descendants(matching: .any)["album.cell.0"].isHittable, "the first row scrolled away")
    // Row 1 col 1 → row 2 col 3: photos 0 to 5 in reading order.
    cell(0).press(forDuration: 0.05, thenDragTo: cell(5))
    waitUntil(timeout: 3) { count.label.hasPrefix("6 of") }
    XCTAssertTrue(count.label.hasPrefix("6 of"), "drag from photo 1 to 6: \(count.label)")
    shot("d1-drag-selected")

    // From a selected photo, sideways: deselects what it passes.
    cell(5).press(forDuration: 0.05, thenDragTo: cell(3))
    waitUntil(timeout: 3) { count.label.hasPrefix("3 of") }
    XCTAssertTrue(count.label.hasPrefix("3 of"), "drag back from photo 6 to 4: \(count.label)")

    // Up/down still scrolls and selects nothing.
    let first = app.descendants(matching: .any)["album.cell.0"]
    let top = first.frame.minY
    cell(4).press(forDuration: 0.05, thenDragTo: cell(1).withOffset(CGVector(dx: 0, dy: -200)))
    sleep(1)
    XCTAssertLessThan(first.frame.minY, top - 50, "an upward swipe didn't scroll the grid")
    XCTAssertTrue(count.label.hasPrefix("3 of"), "an upward swipe changed the selection: \(count.label)")
  }

  /// A slow press still selects on release. With a tap gesture, presses held past about half a second were dropped
  /// (docs/investigations/2026-11-27-grid-interactions.md); the cell is a button now. Creates nothing.
  @MainActor
  func testSlowPressSelects() throws {
    let app = launch(extra: ["-UITestOpen", "album"], home: false)
    let count = app.staticTexts["album.count"]
    XCTAssertTrue(count.waitForExistence(timeout: 20), "the Make album grid didn't open")
    let cell = app.descendants(matching: .any)["album.cell.1"]
    XCTAssertTrue(cell.waitForExistence(timeout: 5))
    XCTAssertTrue(count.label.hasPrefix("0 of"), count.label)
    cell.press(forDuration: 1.5)
    waitUntil(timeout: 3) { count.label.hasPrefix("1 of") }
    XCTAssertTrue(count.label.hasPrefix("1 of"), "a 1.5 s press didn't select: \(count.label)")
  }

  /// Swipe to select, holding the finger at the bottom edge: the grid scrolls and the selection follows the finger.
  @MainActor
  func testDragSelectAutoscrolls() throws {
    let app = launch(extra: ["-UITestOpen", "album"], home: false)
    let count = app.staticTexts["album.count"]
    let create = app.buttons["album.create"]
    XCTAssertTrue(create.waitForExistence(timeout: 20), "the Make album grid didn't open")
    let first = app.descendants(matching: .any)["album.cell.0"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    let top = first.frame.minY

    // From the third row's first photo sideways and down to just above the Add button (mostly sideways, so it
    // selects), then hold.
    let start = app.descendants(matching: .any)["album.cell.6"].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
    let edge = create.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0)).withOffset(CGVector(dx: 0, dy: -24))
    XCTAssertGreaterThan(edge.screenPoint.x - start.screenPoint.x, edge.screenPoint.y - start.screenPoint.y,
                         "the drag must start sideways")
    start.press(forDuration: 0.05, thenDragTo: edge, withVelocity: .default, thenHoldForDuration: 2)
    shot("d2-autoscrolled")
    let selected = Int(count.label.prefix { $0.isNumber }) ?? 0
    XCTAssertGreaterThan(selected, 12, "holding at the bottom edge didn't scroll the selection on: \(count.label)")
    XCTAssertLessThan(first.frame.minY, top - 100, "holding at the bottom edge didn't scroll")
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
  private func launch(extra: [String] = [], home: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestSkipPaywall", "-onboardingComplete", "YES", "-UITestStubEmbedder"] + extra
    app.launch()
    let allow = app.buttons["Allow Photos access"]
    if allow.waitForExistence(timeout: 5) { allow.tap() }
    allowPhotosAccessIfAsked()
    if home { XCTAssertTrue(app.buttons["home.card.screenshots"].waitForExistence(timeout: 60)) }
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
