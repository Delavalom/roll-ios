import XCTest

/// Part 2: destructive QA, only on the throwaway album "Roll QA" (`-QAAlbum`). Needs `ROLL_DEVICE_QA_DESTRUCTIVE=1`
/// as well, and refuses to start unless the app reports the album exists with at most 40 items. Deleted items go to
/// Recently Deleted (30 days).
final class DeviceQA2DestructiveTests: DeviceQABase {
  static let album = "Roll QA"
  static let maxItems = 40

  override func setUpWithError() throws {
    try requireDeviceQA()
    guard ProcessInfo.processInfo.environment["ROLL_DEVICE_QA_DESTRUCTIVE"] == "1" else {
      throw XCTSkip("destructive QA runs only with TEST_RUNNER_ROLL_DEVICE_QA_DESTRUCTIVE=1")
    }
  }

  /// Launches in QA-album mode (fresh state unless `reset` is false; `-QAAlbum` runs keep their own database, so the
  /// reset never touches the real one), onboards, and checks the scope badge.
  @MainActor
  func launchQA(_ name: String, reset: Bool = true, extra: [String] = []) throws -> XCUIApplication {
    declineLeftoverSystemAlert(name)
    let app = XCUIApplication()
    app.launchArguments += ["-QAAlbum", Self.album, "-UITestSkipPaywall"] + extra
    if reset { app.launchArguments.append("-UITestResetState") }
    app.launch()
    if reset { onboard(app, prefix: "\(name)-00", tasteScanTimeout: 300) }
    XCTAssertTrue(app.navigationBars["Roll"].waitForExistence(timeout: 30))
    try requireScope(app)
    return app
  }

  /// A system prompt an earlier test left up (a squish's delete prompt outlives the app) would take the next launch's
  /// taps (D5, 2026-10-24: onboarding stopped on the permission page). Declines it: the original stays.
  @MainActor
  func declineLeftoverSystemAlert(_ name: String) {
    let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    guard alert.exists else { return }
    attachText("\(name)-leftover-alert", alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
    shot("\(name)-leftover-alert")
    let decline = alertButton(alert, "Don't Allow")
    if decline.exists { decline.tap() } else { alert.buttons.firstMatch.tap() }
    _ = waitUntil(timeout: 5) { !alert.exists }
  }

  /// Refuses to go on unless the badge says the QA album exists with 1...40 items.
  @MainActor
  func requireScope(_ app: XCUIApplication) throws {
    let badge = app.staticTexts["qa.scope"]
    guard badge.waitForExistence(timeout: 20) else {
      XCTFail("no QA scope badge: is -QAAlbum honoured (DEBUG build)?")
      throw XCTSkip("refused: no QA scope")
    }
    var count = -1
    _ = waitUntil(timeout: 20) {
      if let m = badge.label.firstMatch(of: /: (\d+) items/) { count = Int(m.1) ?? -1 }
      return count >= 0 || badge.label.contains("missing") || badge.label.contains("ambiguous")
    }
    attachText("qa-scope", badge.label)
    guard (1...Self.maxItems).contains(count) else {
      XCTFail("refused: \(badge.label) (needs the album \"\(Self.album)\" with 1...\(Self.maxItems) items)")
      throw XCTSkip("refused: QA scope not safe")
    }
  }

  @MainActor
  func openSquish(_ app: XCUIApplication) {
    let card = app.buttons["home.card.bigVideos"]
    reveal(card, in: app)
    XCTAssertTrue(card.waitForExistence(timeout: 15))
    card.tap()
    _ = app.navigationBars["Squish"].waitForExistence(timeout: 10)
    sleep(4)
  }

  /// Opens Squish and reopens it every 20 s (it refreshes on open) until `ready` holds or `timeout` passes: locality
  /// checks and format probes run in the background after indexing.
  @MainActor
  @discardableResult
  func openSquish(_ app: XCUIApplication, until ready: () -> Bool, timeout: TimeInterval) -> Bool {
    openSquish(app)
    let deadline = Date().addingTimeInterval(timeout)
    while !ready(), Date() < deadline {
      sleep(20)
      if ready() { break }
      back(app)
      openSquish(app)
    }
    return ready()
  }

  /// Candidate rows (their labels: "about 120 MB → about 40 MB, Video, …, −66%").
  @MainActor
  func candidateRows(_ app: XCUIApplication) -> [XCUIElement] {
    app.buttons.matching(NSPredicate(format: "label CONTAINS '→' AND (label CONTAINS 'Video' OR label CONTAINS 'Photo')"))
      .allElementsBoundByIndex
  }

  /// A candidate row by what it shows: its label, and which of the rows with that label it is (0 for the first).
  /// Positions go stale when a background refresh reorders the list; a key keeps pointing at the same item.
  struct Candidate: Hashable {
    let label: String
    let occurrence: Int
  }

  /// The candidate rows now, in list order, as keys (one fresh read of their labels).
  @MainActor
  func candidates(_ app: XCUIApplication) -> [Candidate] {
    var seen: [String: Int] = [:]
    return candidateRows(app).map { row in
      let label = row.label
      defer { seen[label, default: 0] += 1 }
      return Candidate(label: label, occurrence: seen[label, default: 0])
    }
  }

  /// The row for `key`, looked up by its label every time it's used (never by position).
  @MainActor
  func row(_ key: Candidate, in app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", key.label)).element(boundBy: key.occurrence)
  }

  /// The candidates whose original is on this iPhone (no "in iCloud" in the label): only those squish without a
  /// download (the iCloud-downloads toggle stays off in QA).
  @MainActor
  func localCandidates(_ app: XCUIApplication) -> [Candidate] {
    candidates(app).filter { !$0.label.contains("in iCloud") }
  }

  /// Makes exactly the `keep` rows selected. Launch with `-QASquishStartEmpty`: by default local items start selected,
  /// and a video below the fold is selected when its probe finishes, out of this helper's reach (D2, 2026-10-24). Each pass
  /// re-reads the rows and finds every one by its key, so a refresh that reorders the list can't redirect a tap to
  /// another item; it repeats (up to 3 passes) until a pass changes nothing, then checks the outcome. Taps only once
  /// the list has stopped scrolling and the row is hittable: a tap at a stale frame can land on the Squish bar and open
  /// the confirm sheet early (D5, 2026-10-24).
  @MainActor
  func select(only keep: Set<Candidate>, in app: XCUIApplication) {
    for _ in 0..<3 {
      var tapped = false
      for key in candidates(app) {
        let target = row(key, in: app)
        guard target.exists else { continue }  // gone since the read: the next pass re-reads
        revealAboveBar(target, in: app)
        guard target.exists, target.isSelected != keep.contains(key) else { continue }
        sleep(1)
        guard target.exists, target.isSelected != keep.contains(key) else { continue }
        guard target.isHittable, isAboveBar(target, in: app) else {
          XCTFail("candidate isn't clear of the Squish bar: \(key.label)")
          continue
        }
        target.tap()
        tapped = true
        if confirmSheet(app).waitForExistence(timeout: 1) {
          // The tap reached the Squish bar after all: back out of the sheet before anything else can touch it.
          app.buttons["Cancel"].tap()
          XCTFail("a tap on \(key.label) opened the confirm sheet; cancelled it")
          return
        }
      }
      scrollToTop(app)
      if !tapped { break }
    }
    verifySelection(keep, in: app)
  }

  /// The confirm sheet's own button ("Squish N items", no savings in the label).
  @MainActor
  func confirmSheet(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label MATCHES %@", "Squish [0-9,]+ items?")).firstMatch
  }

  /// Whether `element` sits wholly above the Squish bar and the tab bar. A row half under the bar counts as hittable,
  /// and its tap lands on the bar: D5 (2026-10-25) opened the confirm sheet that way while selecting.
  @MainActor
  func isAboveBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Squish ' AND label CONTAINS 'saves'")).firstMatch
    let tabs = app.tabBars.firstMatch
    var floor = app.frame.maxY
    if bar.exists { floor = min(floor, bar.frame.minY) }
    if tabs.exists { floor = min(floor, tabs.frame.minY) }
    return element.frame.maxY <= floor - 4
  }

  /// Scrolls in short drags (a swipe can carry a row past the top) until `element` is hittable and clear of the bars.
  @MainActor
  func revealAboveBar(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 where !(element.exists && element.isHittable && isAboveBar(element, in: app)) {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
      start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
      sleep(1)
    }
  }

  /// Back to the top of the list, where every pass and check starts (Squish has no pull-to-refresh).
  @MainActor
  func scrollToTop(_ app: XCUIApplication) {
    for _ in 0..<3 { app.swipeDown() }
    sleep(1)
  }

  /// Fails (and so stops the test before anything is squished) unless every `keep` row is there and selected, no other
  /// visible row is selected, and the Squish bar counts exactly `keep.count` items (rows off screen included).
  @MainActor
  func verifySelection(_ keep: Set<Candidate>, in app: XCUIApplication) {
    let visible = candidates(app)
    let extra = visible.filter { !keep.contains($0) && row($0, in: app).isSelected }
    var missing: [Candidate] = []
    for key in keep.sorted(by: { ($0.label, $0.occurrence) < ($1.label, $1.occurrence) }) {
      let target = row(key, in: app)
      if !visible.contains(key) { reveal(target, in: app) }
      if !(target.exists && target.isSelected) { missing.append(key) }
    }
    scrollToTop(app)
    let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Squish ' AND label CONTAINS 'saves'")).firstMatch
    let barCount = bar.exists
      ? bar.label.firstMatch(of: /Squish ([0-9,]+) item/).flatMap { Int($0.1.replacingOccurrences(of: ",", with: "")) }
      : 0
    if !extra.isEmpty || !missing.isEmpty || barCount != keep.count {
      XCTFail("""
        the selection isn't the intended one (the list may have changed under the test)
        wanted: \(keep.map(\.label).sorted())
        not selected or gone: \(missing.map(\.label))
        selected but not wanted: \(extra.map(\.label))
        Squish bar: \(bar.exists ? bar.label : "none") (expected \(keep.count) items)
        """)
    }
  }

  @MainActor
  func startSquish(_ app: XCUIApplication, shotName: String) {
    // The list's button reads "Squish N items, saves about …"; the sheet's own button reads exactly "Squish N items".
    let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Squish ' AND label CONTAINS 'saves'"))
      .firstMatch
    let apply = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "Squish [0-9,]+ items?")).firstMatch
    XCTAssertFalse(apply.exists, "the confirm sheet is already open (a stray tap?)")
    XCTAssertTrue(start.waitForExistence(timeout: 10), "no Squish button (nothing selected?)")
    start.tap()
    XCTAssertTrue(apply.waitForExistence(timeout: 15), "the confirm sheet didn't open")
    _ = waitUntil(timeout: 15) { apply.isEnabled }
    sleep(2)
    shot("\(shotName)-confirm-sheet")
    app.swipeUp()
    shot("\(shotName)-confirm-sheet-disclosures")
    let shared = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'iCloud Shared Library'")).firstMatch
    let captions = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Captions, keywords and people tags'")).firstMatch
    attachText("\(shotName)-disclosures", "shared library line: \(shared.exists), captions line: \(captions.exists)")
    app.swipeDown()
    apply.tap()
  }
}
