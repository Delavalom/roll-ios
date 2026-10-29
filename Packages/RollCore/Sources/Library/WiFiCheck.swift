/// The network path, as far as iCloud downloads care (the app maps `NWPath` to it).
public struct NetworkPath: Sendable, Equatable {
  public var isSatisfied: Bool
  /// A cellular or personal-hotspot path (`NWPath.isExpensive`).
  public var isExpensive: Bool
  /// Low Data Mode (`NWPath.isConstrained`).
  public var isConstrained: Bool
  public var usesWiFiOrWired: Bool

  public init(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool, usesWiFiOrWired: Bool) {
    self.isSatisfied = isSatisfied
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
    self.usesWiFiOrWired = usesWiFiOrWired
  }

  /// Whether Roll downloads from iCloud (swipe cards, full screen, squish originals): Wi-Fi or wired, never an
  /// expensive path. Low Data Mode is deliberately not checked (review of 2026-10-25): a card downloads only the one
  /// photo the user is about to decide on, when nothing local can be shown, and without it the card can only be skipped.
  public var allowsICloudDownloads: Bool { isSatisfied && !isExpensive && usesWiFiOrWired }
}

/// One Wi-Fi answer for a stack of cards. Concurrent callers (the prefetched cards) share one check, and a yes serves
/// `reuseFor` of swiping. A no is never reused: the next card asks again, so joining Wi-Fi takes effect at once.
@MainActor
public final class SharedWiFiCheck {
  public static let reuseFor: Duration = .seconds(15)

  private let check: @Sendable () async -> Bool
  private let reuseFor: Duration
  private var yesAt: ContinuousClock.Instant?
  private var inFlight: Task<Bool, Never>?

  public init(reuseFor: Duration = SharedWiFiCheck.reuseFor, check: @escaping @Sendable () async -> Bool) {
    self.reuseFor = reuseFor
    self.check = check
  }

  public func isOnWiFi() async -> Bool {
    if let yesAt, ContinuousClock.now - yesAt < reuseFor { return true }
    let task = inFlight ?? Task { [check] in await check() }
    inFlight = task
    let onWiFi = await task.value
    if inFlight == task { inFlight = nil }
    if onWiFi { yesAt = .now }
    return onWiFi
  }

  /// The path changed (a path monitor): a yes is remembered, a no forgets the last yes.
  public func pathChanged(onWiFi: Bool) {
    yesAt = onWiFi ? .now : nil
  }
}
