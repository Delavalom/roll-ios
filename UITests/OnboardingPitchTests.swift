import XCTest

/// The paywall after the taste scan leads with the scan's own number: "You can free about X on this iPhone" on the
/// results, then "Free about X on this iPhone" on the paywall, the same X. Below `PaywallPitch.minimumBytes` (100 MB)
/// the paywall keeps its generic header. Needs the seeded Roll-QA simulator (`just seed-sim`); the headline doesn't
/// need RevenueCat, so it runs without the network.
final class OnboardingPitchTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testPaywallAfterTheTasteScanRepeatsItsNumber() throws {
    let app = XCUIApplication()
    app.launchArguments += ["-UITestStubEmbedder", "-UITestResetState"]
    app.launch()

    // One intro page, then the permission step.
    for _ in 0..<2 {
      let next = app.buttons["Continue"]
      XCTAssertTrue(next.waitForExistence(timeout: 15))
      waitUntil(timeout: 10) { next.isHittable && next.isEnabled }
      next.tap()
    }
    allowPhotosAccessIfAsked()

    let found = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'You can free about' OR "
      + "label BEGINSWITH 'Nothing confirmed on this iPhone' OR label BEGINSWITH 'Nothing big to free'")).firstMatch
    XCTAssertTrue(found.waitForExistence(timeout: 120), "the taste scan didn't finish")
    let continueButton = app.buttons["Continue"]
    waitUntil(timeout: 10) { continueButton.isEnabled }
    let scanLine = found.label
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "taste-scan-result"
    attachment.lifetime = .keepAlways
    add(attachment)
    continueButton.tap()

    let headline = app.staticTexts["paywall.headline"]
    XCTAssertTrue(headline.waitForExistence(timeout: 15), "the paywall didn't follow the taste scan")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "paywall-after-taste-scan"
    shot.lifetime = .keepAlways
    add(shot)

    let size = Self.size(in: scanLine)
    let shown = size.map(Self.bytes) ?? 0
    // "100 MB" on screen can be 99.6 MB underneath: right at the floor either header is correct.
    if abs(shown - 100_000_000) < 1_000_000 { return }
    if let size, shown >= 100_000_000 {
      XCTAssertEqual(Self.normalized(headline.label), "Free about \(size) on this iPhone", "scan said: \(scanLine)")
      XCTAssertTrue(app.staticTexts["paywall.subline"].exists, "the subline names what was found")
    } else {
      XCTAssertEqual(headline.label, "Clean up your camera roll, privately", "scan said: \(scanLine)")
    }
  }

  /// "You can free about 1.2 GB on this iPhone" → "1.2 GB" (non-breaking spaces made plain).
  private static func size(in line: String) -> String? {
    let plain = normalized(line)
    guard let match = plain.firstMatch(of: /You can free about (.+) on this iPhone/) else { return nil }
    return String(match.1)
  }

  private static func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ") }

  /// "1.2 GB" → 1_200_000_000 (decimal units, as the byte-count formatter's file style uses).
  private static func bytes(_ size: String) -> Double {
    let parts = size.split(separator: " ")
    guard parts.count == 2, let value = Double(parts[0].replacingOccurrences(of: ",", with: "")) else { return 0 }
    let scale: Double = switch parts[1] {
    case "KB", "kB": 1e3
    case "MB": 1e6
    case "GB": 1e9
    case "TB": 1e12
    default: 1
    }
    return value * scale
  }

  /// The Photos permission prompt belongs to SpringBoard.
  @MainActor
  private func allowPhotosAccessIfAsked() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.alerts.buttons.matching(NSPredicate(
      format: "label CONTAINS[c] 'Full Access' OR label CONTAINS[c] 'All Photos' OR label ==[c] 'Allow'")).firstMatch
    if allow.waitForExistence(timeout: 15) { allow.tap() }
  }

  @MainActor
  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
  }
}
