import XCTest

/// Part 2's cases, D00 to D5 (the helpers are in DeviceQA2DestructiveTests.swift).
extension DeviceQA2DestructiveTests {
  /// D00 (sorts first): restocks the album with originals stored on the iPhone. `scripts/qa_restock.sh <udid>` stages
  /// two 12 MP JPEGs, a PNG photo and two 1080p H.264 clips in Roll's `Documents/qa-restock/`; `-QARestock` takes as
  /// few iCloud-only items out of the album as needed (never deletes them) to fill it to 32, leaving room for the copies
  /// the pass saves, imports the files into it and removes them from Documents. With nothing staged it still takes an
  /// album over 32 back down (a failed pass can leave 41). The album must then hold 1...40 items. Skipped when nothing
  /// is staged and the album is within 32.
  @MainActor
  func testD00RestockAlbum() throws {
    declineLeftoverSystemAlert("d00")
    let app = XCUIApplication()
    app.launchArguments += ["-QAAlbum", Self.album, "-QARestock", "-UITestSkipPaywall"]
    app.launch()
    // A QA database that hasn't onboarded yet has no Photos access: onboard first (the restock waits for full access).
    let home = app.navigationBars["Roll"], onboarding = app.buttons["Continue"]
    _ = waitUntil(timeout: 30) { home.exists || onboarding.exists }
    if !home.exists, onboarding.exists { onboard(app, prefix: "d00-00", tasteScanTimeout: 300) }
    XCTAssertTrue(home.waitForExistence(timeout: 30))
    let restock = app.staticTexts["qa.restock"]
    XCTAssertTrue(restock.waitForExistence(timeout: 20), "no restock status: is -QARestock honoured (DEBUG build)?")
    let finished = waitUntil(timeout: 600, poll: 2) {
      !restock.label.contains("waiting") && !restock.label.contains("running")
    }
    attachText("d00-restock", restock.label)
    shot("d00-01-restocked")
    XCTAssertTrue(finished, "the restock didn't finish in 10 minutes: \(restock.label)")
    if restock.label.contains("nothing to import") {
      throw XCTSkip("nothing staged in Documents/qa-restock (run scripts/qa_restock.sh <udid> first)")
    }
    XCTAssertTrue(restock.label.hasPrefix("QA restock: done"), restock.label)
    try requireScope(app)
  }

  /// D1: the album's contents through Roll (inventory, Squish candidates and refusals, duplicates). Changes nothing.
  @MainActor
  func testD1InventoryAndRefusals() throws {
    let app = try launchQA("d1", extra: ["-QADolbyVisionExperiment"])
    shot("d1-01-home")
    // Dolby Vision shows up as "HDR video kept as is" once the original is confirmed local and its format probed.
    let hdr = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'HDR video kept as is'")).firstMatch
    let found = openSquish(app, until: { hdr.exists }, timeout: 240)
    attachText("d1-hdr-kept", found ? hdr.label : "no 'HDR video kept as is' section after 240 s")
    shot("d1-02-squish")
    let refused = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Not squishable yet'")).firstMatch
    reveal(refused, in: app)
    if refused.exists {
      refused.tap()
      sleep(2)
      shot("d1-03-not-squishable")
      app.swipeUp()
      shot("d1-03-not-squishable-scrolled")
    }
    attachText("d1-candidates", candidateRows(app).map(\.label).joined(separator: "\n"))
    back(app)
    for kind in ["duplicates", "similarShots", "screenshots", "blurry"] {
      let card = app.buttons["home.card.\(kind)"]
      reveal(card, in: app)
      guard card.exists else { continue }
      card.tap()
      sleep(4)
      shot("d1-04-\(kind)")
      back(app)
      app.swipeDown()
    }
    // Let the inventory and the Dolby Vision experiment (temp files only) finish.
    sleep(240)
  }

  /// D0: an earlier run that ended with the delete prompt still open (the app was killed after the copies were saved)
  /// leaves verified copies next to their originals. Relaunching must report it, and "Remove copies" must remove them
  /// and keep the originals, so the album is back to its own items before D1. Skipped when nothing is unfinished.
  @MainActor
  func testD0RecoverAnUnfinishedSquishFromAnEarlierRun() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-QAAlbum", Self.album, "-UITestSkipPaywall"]
    app.launch()
    let banner = app.staticTexts["A squish didn't finish"]
    guard banner.waitForExistence(timeout: 30) else { throw XCTSkip("no unfinished squish") }
    shot("d0-01-recovery-banner")
    attachText("d0-home", app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
    let remove = app.buttons["Remove copies"]
    reveal(remove, in: app)
    XCTAssertTrue(remove.waitForExistence(timeout: 10))
    remove.tap()
    attachText("d0-discard-alert", tapSystemAlert(app, button: "Delete", timeout: 30) ?? "no alert")
    XCTAssertTrue(waitUntil(timeout: 30) { !banner.exists }, "the banner should clear after removing the copies")
    shot("d0-02-after-remove-copies")
    try requireScope(app)
  }

  /// D2 (case 14, space): with `-QAFakeAvailableBytes` the flow sees 100 MB free and must refuse before exporting.
  @MainActor
  func testD2InsufficientSpaceRefusesFirst() throws {
    let app = try launchQA("d2", extra: ["-QASquishStartEmpty", "-QAFakeAvailableBytes", "100000000"])
    // A local row: iCloud rows can't be ticked while iCloud downloads are off.
    openSquish(app, until: { !self.localCandidates(app).isEmpty }, timeout: 180)
    guard let last = localCandidates(app).last else { throw XCTSkip("no local squish candidates in \(Self.album)") }
    select(only: [last], in: app)
    startSquish(app, shotName: "d2")
    let reason = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'free space'")).firstMatch
    XCTAssertTrue(reason.waitForExistence(timeout: 60), "expected the insufficient-space refusal")
    shot("d2-01-refused-no-space")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertFalse(springboard.alerts.firstMatch.exists, "no delete prompt may appear")
    app.buttons["Done"].tap()
  }

  /// D3 (case 11): kill the app after the copy is saved and verified, before the delete prompt (the pause hook holds
  /// it there). On relaunch reconcile lists the verified pair; Squish and Duplicates don't offer the copy; "Remove
  /// copies" removes it and keeps the original.
  @MainActor
  func testD3KillBeforeDeletePromptThenRecover() throws {
    let app = try launchQA("d3", extra: ["-QASquishStartEmpty", "-QAPauseBeforeSquishDelete"])
    openSquish(app, until: { !self.candidateRows(app).isEmpty }, timeout: 180)
    guard let smallest = localCandidates(app).last else { throw XCTSkip("no local squish candidates in \(Self.album)") }
    attachText("d3-candidate", smallest.label)
    select(only: [smallest], in: app)
    startSquish(app, shotName: "d3")
    let paused = app.buttons["qa.continueDelete"]
    XCTAssertTrue(paused.waitForExistence(timeout: 600), "the squish never reached the delete step")
    shot("d3-01-paused-before-delete")
    app.terminate()

    let relaunched = try launchQA("d3", reset: false, extra: ["-QASquishStartEmpty", "-QAPauseBeforeSquishDelete"])
    let banner = relaunched.staticTexts["A squish didn't finish"]
    XCTAssertTrue(banner.waitForExistence(timeout: 30), "reconcile didn't report the interrupted squish")
    shot("d3-02-recovery-banner")
    openSquish(relaunched)
    shot("d3-03-squish-after-kill")
    back(relaunched)
    for kind in ["duplicates", "similarShots"] {
      let card = relaunched.buttons["home.card.\(kind)"]
      reveal(card, in: relaunched)
      guard card.exists else { continue }
      card.tap()
      sleep(4)
      shot("d3-04-\(kind)-after-kill")
      back(relaunched)
    }
    relaunched.swipeDown()
    let remove = relaunched.buttons["Remove copies"]
    XCTAssertTrue(remove.waitForExistence(timeout: 10))
    remove.tap()
    let alert = tapSystemAlert(relaunched, button: "Delete", timeout: 30)
    attachText("d3-discard-alert", alert ?? "no alert")
    XCTAssertTrue(waitUntil(timeout: 30) { !banner.exists }, "the banner should clear after removing the copy")
    shot("d3-05-after-remove-copies")
  }

  /// D4 (case 12): send the app home mid-encode, wait, come back. The item finishes or cancels cleanly.
  @MainActor
  func testD4BackgroundMidEncode() throws {
    let app = try launchQA("d4", extra: ["-QASquishStartEmpty"])
    // The video with the biggest estimated saving: the largest can be an HEVC copy Roll made earlier (the QA reset
    // forgets finished squishes), which is refused as not smaller before any encoding (2026-10-24).
    let saving = { (c: Candidate) in c.label.firstMatch(of: /−(\d+)%/).flatMap { Int($0.1) } ?? 0 }
    let localVideo = { self.localCandidates(app).filter { $0.label.contains("Video") }.max { saving($0) < saving($1) } }
    openSquish(app, until: { localVideo() != nil }, timeout: 180)
    guard let video = localVideo() else { throw XCTSkip("no local video squish candidate in \(Self.album)") }
    attachText("d4-candidate", video.label)
    select(only: [video], in: app)
    startSquish(app, shotName: "d4")
    let encoding = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'encoding'")).firstMatch
    XCTAssertTrue(encoding.waitForExistence(timeout: 120), "never saw the encoding step")
    XCUIDevice.shared.press(.home)
    sleep(20)  // short: on the home screen nothing keeps the phone awake
    app.activate()
    sleep(3)
    shot("d4-01-back-from-background")
    // Either the prompt comes (the encode finished, in the background or after) or the sheet reports a stop. A 45 s
    // clip was still "Replacing" 2 minutes after coming back (2026-10-24), and its prompt then landed on D5: wait until
    // the run has ended either way, and fail if it hasn't.
    let replacing = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Replacing'")).firstMatch
    var alertText: String?
    _ = waitUntil(timeout: 600, poll: 2) {
      alertText = self.tapSystemAlert(app, button: "Don't Allow", timeout: 1)
      return alertText != nil || !replacing.exists
    }
    if let alertText { attachText("d4-delete-alert", alertText) }
    sleep(3)
    shot("d4-02-outcome")
    attachText("d4-outcome", app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
    XCTAssertTrue(alertText != nil || !replacing.exists, "the squish was still running 10 minutes after coming back")
    let remove = app.buttons["Remove the copies"]
    if remove.exists {
      remove.tap()
      _ = tapSystemAlert(app, button: "Delete", timeout: 30)
      sleep(3)
      shot("d4-03-copies-removed")
    }
  }

  /// D5 (basic flow, decline, retry; cases 13 and 14): squish every remaining candidate, decline the delete prompt
  /// (copies and originals stay), then "Replace the originals" and allow it. Per-item bytes are in the metrics.
  @MainActor
  func testD5SquishDeclineThenReplace() throws {
    let app = try launchQA("d5", extra: ["-QASquishStartEmpty"])
    openSquish(app, until: { !self.candidateRows(app).isEmpty }, timeout: 180)
    guard !candidateRows(app).isEmpty else { throw XCTSkip("no squish candidates in \(Self.album)") }
    attachText("d5-candidates", candidateRows(app).map(\.label).joined(separator: "\n"))
    select(only: Set(localCandidates(app)), in: app)
    startSquish(app, shotName: "d5")
    let declined = tapSystemAlert(app, button: "Don't Allow", timeout: 1_200)
    attachText("d5-delete-alert", declined ?? "no alert")
    guard declined != nil else {
      shot("d5-01-no-prompt")
      attachText("d5-outcome", app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
      XCTFail("no delete prompt (every item refused or failed?)")
      return
    }
    let replace = app.buttons["Replace the originals"]
    XCTAssertTrue(replace.waitForExistence(timeout: 30), "after Don't Allow the copies should be waiting")
    shot("d5-01-declined-copies-waiting")
    replace.tap()
    XCTAssertNotNil(tapSystemAlert(app, button: "Delete", timeout: 60))
    let squished = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Squished'")).firstMatch
    XCTAssertTrue(squished.waitForExistence(timeout: 60))
    sleep(2)
    shot("d5-02-squished")
    app.swipeUp()
    shot("d5-02-squished-scrolled")
    attachText("d5-outcome", app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
    app.buttons["Done"].tap()
    sleep(30)  // the copies' metadata check and the next inventory land in the metrics
  }
}
