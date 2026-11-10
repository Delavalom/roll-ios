import Foundation

/// The categories the taste scan lists ("Here's what Roll found"), in its order. Duplicates include similar shots;
/// big videos count at what squishing them saves.
public enum FoundKind: Sendable, Equatable, CaseIterable {
  case screenshots, duplicates, bigVideos, blurry

  /// The taste scan's row title.
  public var title: String {
    switch self {
    case .screenshots: "Screenshots"
    case .duplicates: "Duplicates and similar shots"
    case .bigVideos: "Squishing big videos"
    case .blurry: "Blurry"
    }
  }

  /// How the paywall's subline names it: "Mostly screenshots, plus blurry photos."
  public var phrase: String {
    switch self {
    case .screenshots: "screenshots"
    case .duplicates: "duplicates and similar shots"
    case .bigVideos: "big videos Roll can squish"
    case .blurry: "blurry photos"
    }
  }
}

/// One found category and what it frees on this iPhone.
public struct FoundItem: Sendable, Equatable {
  public var kind: FoundKind
  public var bytes: Int64

  public init(kind: FoundKind, bytes: Int64) { self.kind = kind; self.bytes = bytes }
}

extension CleanupSummary {
  /// What each found category frees on this iPhone (originals in iCloud are left out), in the taste scan's order.
  /// Categories with nothing on the device are dropped (never "about 0 MB").
  public var foundOnDevice: [FoundItem] {
    [
      FoundItem(kind: .screenshots, bytes: self[.screenshots].onDeviceBytes),
      FoundItem(kind: .duplicates, bytes: self[.duplicates].onDeviceBytes + self[.similarShots].onDeviceBytes),
      FoundItem(kind: .bigVideos, bytes: bigVideoSavingsOnDevice),
      FoundItem(kind: .blurry, bytes: self[.blurry].onDeviceBytes),
    ].filter { $0.bytes > 0 }
  }
}

/// The paywall's opening line when Roll has a number worth leading with: "Free about 3.2 GB on this iPhone", and the
/// biggest one or two categories behind it. nil means the generic header.
public struct PaywallPitch: Sendable, Equatable {
  /// 100 MB. Below it the number undersells Pro: it's less than a minute of 4K video or one app update, the kind of
  /// space people clear by hand, and putting it next to a yearly price invites the comparison. From 100 MB the figure
  /// is a real chunk of storage, and on most libraries the taste scan alone passes it.
  public static let minimumBytes: Int64 = 100_000_000

  /// Exactly the on-device headline the user was shown (never recomputed here).
  public let bytes: Int64
  /// "Mostly screenshots, plus blurry photos." or "All from screenshots."; nil when no category has bytes.
  public let subline: String?

  /// - Parameters:
  ///   - onDeviceBytes: the headline the taste scan or Home showed: on this iPhone only, already capped.
  ///   - found: the categories behind it, on this iPhone only (`CleanupSummary.foundOnDevice`).
  public static func make(onDeviceBytes: Int64, found: [FoundItem]) -> PaywallPitch? {
    guard onDeviceBytes >= minimumBytes else { return nil }
    // Biggest first; a stable sort keeps the scan's order on ties.
    let top = found.enumerated().filter { $0.element.bytes > 0 }
      .sorted { ($0.element.bytes, $1.offset) > ($1.element.bytes, $0.offset) }
      .prefix(2).map(\.element.kind)
    let subline: String? = switch top.count {
    case 0: nil
    case 1: "All from \(top[0].phrase)."
    default: "Mostly \(top[0].phrase), plus \(top[1].phrase)."
    }
    return PaywallPitch(bytes: onDeviceBytes, subline: subline)
  }

  /// From a summary, with the same cap as Home's header (`CleanupSummary.onDeviceHeadline`).
  public static func make(summary: CleanupSummary, deviceTotal: Int64?, deviceAvailable: Int64?) -> PaywallPitch? {
    make(onDeviceBytes: summary.onDeviceHeadline(deviceTotal: deviceTotal, deviceAvailable: deviceAvailable),
         found: summary.foundOnDevice)
  }
}
