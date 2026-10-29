import Synchronization
import Testing
@testable import Library

/// The Wi-Fi answer swipe cards share (review of 2026-10-25: concurrent prefetches each ran a check, and a "no" was
/// cached, so cards stayed "Not on this iPhone" after the phone joined Wi-Fi).
@MainActor
struct WiFiCheckTests {
  /// Counts checks; each answers `answer` after a short wait, so concurrent callers overlap.
  final class Checks: Sendable {
    let count = Mutex(0)
    let answer: Mutex<Bool>
    init(_ answer: Bool) { self.answer = Mutex(answer) }
    func run() async -> Bool {
      count.withLock { $0 += 1 }
      try? await Task.sleep(for: .milliseconds(30))
      return answer.withLock { $0 }
    }
  }

  @Test func concurrentCardsShareOneCheck() async {
    let checks = Checks(true)
    let wifi = SharedWiFiCheck { await checks.run() }
    async let a = wifi.isOnWiFi()
    async let b = wifi.isOnWiFi()
    async let c = wifi.isOnWiFi()
    let answers = await [a, b, c]
    #expect(answers == [true, true, true])
    #expect(checks.count.withLock { $0 } == 1)
    #expect(await wifi.isOnWiFi(), "a yes is reused")
    #expect(checks.count.withLock { $0 } == 1)
  }

  @Test func aNoIsNeverReused() async {
    let checks = Checks(false)
    let wifi = SharedWiFiCheck { await checks.run() }
    #expect(await wifi.isOnWiFi() == false)
    checks.answer.withLock { $0 = true }  // the phone joins Wi-Fi
    #expect(await wifi.isOnWiFi(), "the next card asks again")
    #expect(checks.count.withLock { $0 } == 2)
  }

  @Test func aYesExpiresAndLeavingWiFiForgetsIt() async {
    let checks = Checks(true)
    let wifi = SharedWiFiCheck(reuseFor: .zero) { await checks.run() }
    _ = await wifi.isOnWiFi()
    _ = await wifi.isOnWiFi()
    #expect(checks.count.withLock { $0 } == 2, "expired: asked again")

    let reused = SharedWiFiCheck { await checks.run() }
    reused.pathChanged(onWiFi: true)
    #expect(await reused.isOnWiFi())
    #expect(checks.count.withLock { $0 } == 2, "a path monitor's yes counts as an answer")
    reused.pathChanged(onWiFi: false)
    checks.answer.withLock { $0 = false }
    #expect(await reused.isOnWiFi() == false, "left Wi-Fi: the old yes is gone")
  }

  @Test func downloadsNeedWiFiOrWiredNotAnExpensivePathAndLowDataModeDoesntStopThem() {
    let wifi = NetworkPath(isSatisfied: true, isExpensive: false, isConstrained: false, usesWiFiOrWired: true)
    #expect(wifi.allowsICloudDownloads)
    var lowData = wifi
    lowData.isConstrained = true
    #expect(lowData.allowsICloudDownloads, "Low Data Mode: a card still downloads the one photo it must show")
    var hotspot = wifi
    hotspot.isExpensive = true
    #expect(!hotspot.allowsICloudDownloads, "a personal hotspot is Wi-Fi but expensive")
    var cellular = wifi
    cellular.usesWiFiOrWired = false
    #expect(!cellular.allowsICloudDownloads)
    var offline = wifi
    offline.isSatisfied = false
    #expect(!offline.allowsICloudDownloads)
  }
}
