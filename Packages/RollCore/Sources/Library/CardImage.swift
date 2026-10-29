import CoreGraphics
import Foundation

/// How one PhotoKit image request is made. Pure, so the choices are tested; `PhotoLibrary` maps it to
/// `PHImageRequestOptions` (resize mode `.fast`, asynchronous).
public struct ImageRequestSpec: Sendable, Hashable {
  public enum Delivery: Sendable, Hashable {
    /// A degraded local preview first, then the final image (or nothing when the original is only in iCloud).
    case opportunistic
    /// One delivery at the requested quality.
    case highQuality
  }

  public var delivery: Delivery
  public var allowsNetwork: Bool

  public init(delivery: Delivery, allowsNetwork: Bool) {
    self.delivery = delivery
    self.allowsNetwork = allowsNetwork
  }

  /// Network off, one delivery: a real local image at the requested size, never a degraded preview.
  public static let localSharp = ImageRequestSpec(delivery: .highQuality, allowsNetwork: false)
  /// Network off, opportunistic: the full image when it's local, else the small preview iOS keeps for an original only
  /// in iCloud (`ThumbnailResult.preview`). What the Indexer analyses.
  public static let localBest = ImageRequestSpec(delivery: .opportunistic, allowsNetwork: false)
  /// Network on, one delivery. Only on Wi-Fi: the caller checks first.
  public static let download = ImageRequestSpec(delivery: .highQuality, allowsNetwork: true)

  /// The Indexer's flags: with network access a request is always one high-quality delivery.
  public init(allowNetwork: Bool, previews: Bool) {
    self = allowNetwork ? .download : previews ? .localBest : .localSharp
  }
}

/// Where card images come from (PhotoKit in the app, fakes in tests).
public protocol CardImageSource: Sendable {
  /// One request, longer side about `side` pixels, upright.
  func image(for id: String, side: Int, spec: ImageRequestSpec) async -> ThumbnailResult
}

/// What a swipe card (or its full-screen view) shows. The user must see what they decide on: a card with nothing on
/// screen can be skipped, never deleted, kept or moved (`gate`).
public enum CardImage: Sendable {
  /// Looking on the device (a few milliseconds).
  case loading
  /// The best image on the device: a full local image, or (`isPreview`) the small preview iOS keeps for an original
  /// that is only in iCloud.
  case local(CGImage, isPreview: Bool)
  /// Downloading from iCloud on Wi-Fi; `showing` stays on screen meanwhile when there is one.
  case downloading(showing: CGImage?)
  case downloaded(CGImage)
  /// Nothing to show.
  case unavailable(Unavailable)

  public enum Unavailable: Sendable, Equatable {
    /// Only in iCloud with no local preview, and no Wi-Fi (Roll downloads on Wi-Fi only).
    case needsWiFi
    /// Photos returned no image: an error, a failed download, a request Photos cancelled, or the item is gone.
    case failed
    /// Photos didn't answer within `CardImageLoader.lookupTimeout`.
    case timedOut

    public var title: String {
      switch self {
      case .needsWiFi: "Not on this iPhone"
      case .failed: "Can't show this one"
      case .timedOut: "Taking too long"
      }
    }

    public var message: String {
      switch self {
      case .needsWiFi: "It's in iCloud, which downloads on Wi-Fi only. Skip it for now."
      case .failed: "Photos didn't return an image. Skip it for now."
      case .timedOut: "Photos hasn't returned this one yet. Skip it for now."
      }
    }
  }

  public var image: CGImage? {
    switch self {
    case .local(let image, _), .downloaded(let image): image
    case .downloading(let showing): showing
    case .loading, .unavailable: nil
    }
  }

  /// A request is still running (a spinner shows).
  public var isWorking: Bool {
    switch self {
    case .loading, .downloading: true
    default: false
    }
  }

  public var gate: CardGate {
    if image != nil { return .decide }
    if case .loading = self { return .wait }
    return .skipOnly
  }
}

/// What a swipe on a card may do.
public enum CardGate: Sendable, Equatable {
  /// The photo is on screen: every verdict.
  case decide
  /// Still looking on the device: swipes snap back for the moment it takes (at most `CardImageLoader.lookupTimeout`,
  /// then the card is unavailable).
  case wait
  /// Nothing on screen (unavailable, or downloading with nothing to show yet): any swipe skips the card for this
  /// session without recording a decision, so nothing is deleted, kept or learned from a photo the user didn't see.
  case skipOnly
}

/// Which sizes a view asks for.
public struct CardImageRequest: Sendable, Equatable {
  /// Largest first. All but the last are asked for as real local images (`localSharp`); the last as the best local
  /// image (`localBest`), whose fallback is the local preview.
  public var sides: [Int]
  /// On Wi-Fi, download when the best local image's longer side is below this. nil: download only when nothing local
  /// can be shown.
  public var downloadBelow: Int?

  public init(sides: [Int], downloadBelow: Int?) {
    self.sides = sides
    self.downloadBelow = downloadBelow
  }

  /// Swipe cards: 512 px, else 300 px or the local preview. Downloads only when there's nothing at all, so swiping
  /// through an iCloud library doesn't pull originals.
  public static let card = CardImageRequest(sides: [512, 300], downloadBelow: nil)
  /// Full screen (the user asked to look closer): on Wi-Fi, a small local image is replaced by a 2000 px download.
  public static let fullScreen = CardImageRequest(sides: [2000, 512, 300], downloadBelow: 1000)

  var downloadSide: Int { sides.first ?? 512 }
}

public enum CardImageLoader {
  /// How long the local lookups may take in all before the card says so (`.timedOut`) and can be skipped.
  public static let lookupTimeout: Duration = .seconds(8)

  /// Loads the best image for `request` and reports each state through `update` (the caller sets `.loading` first).
  /// `onWiFi` is asked only when a download would help. A cancelled task reports nothing more; a request Photos
  /// cancels on its own (`PHImageCancelledKey` while the task runs) counts as a failure, so no card stays `.loading`.
  public static func load(id: String, request: CardImageRequest, source: some CardImageSource,
                          lookupTimeout: Duration = lookupTimeout, isolation: isolated (any Actor)? = #isolation,
                          onWiFi: () async -> Bool, update: (CardImage) -> Void) async {
    var best: CGImage?
    var isPreview = false
    var missing = CardImage.Unavailable.failed
    let deadline = ContinuousClock.now + lookupTimeout
    for (index, side) in request.sides.enumerated() {
      let last = index == request.sides.count - 1
      let result = await lookUp(id, side: side, spec: last ? .localBest : .localSharp, in: source, until: deadline)
      if Task.isCancelled { return }
      guard let result else {
        if missing != .needsWiFi { missing = .timedOut }
        break
      }
      switch result {
      case .image(let image): best = image
      case .preview(let image): best = image; isPreview = true
      // "In iCloud" at any size wins over a failure at another: the Wi-Fi download can still show it.
      case .inCloud: missing = .needsWiFi
      case .failed, .cancelled: break
      }
      if best != nil { break }
    }
    if let best { update(.local(best, isPreview: isPreview)) }

    let wantsDownload = if let best { request.downloadBelow.map { max(best.width, best.height) < $0 } ?? false }
      else { missing == .needsWiFi }
    guard wantsDownload else {
      if best == nil { update(.unavailable(missing)) }
      return
    }
    let wifi = await onWiFi()
    if Task.isCancelled { return }
    guard wifi else {
      if best == nil { update(.unavailable(.needsWiFi)) }
      return
    }
    update(.downloading(showing: best))
    let result = await source.image(for: id, side: request.downloadSide, spec: .download)
    if Task.isCancelled { return }
    switch result {
    case .image(let image), .preview(let image): update(.downloaded(image))
    case .inCloud, .failed, .cancelled: update(best.map { .local($0, isPreview: isPreview) } ?? .unavailable(.failed))
    }
  }

  /// One local request, or nil when it's still running at `deadline` (it is then cancelled and left behind).
  static func lookUp(_ id: String, side: Int, spec: ImageRequestSpec, in source: some CardImageSource,
                     until deadline: ContinuousClock.Instant) async -> ThumbnailResult? {
    await Deadline.answer(within: deadline - .now) { await source.image(for: id, side: side, spec: spec) }
  }
}

/// Which card images load: the top card and the next three, so a swipe shows a ready card. Cards that leave the window
/// (swiped away) are cancelled, which cancels their PhotoKit request.
public enum CardPrefetch {
  public static let depth = 4

  /// `loading`: ids loading or loaded now. `stack`: the cards, top first. Starts are in stack order.
  public static func plan(loading: Set<String>, stack: [String], depth: Int = depth) -> (start: [String], cancel: [String]) {
    let window = Array(stack.prefix(depth))
    let wanted = Set(window)
    return (window.filter { !loading.contains($0) }, loading.filter { !wanted.contains($0) }.sorted())
  }

  /// The cards in the window to load again (the screen appeared, or the phone joined Wi-Fi): those that are
  /// unavailable. In stack order.
  public static func retry(_ states: [String: CardImage], stack: [String], depth: Int = depth) -> [String] {
    stack.prefix(depth).filter { if case .unavailable = states[$0] { true } else { false } }
  }
}
