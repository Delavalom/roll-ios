import Library
import Observation
import SwiftUI

/// The images of the cards near the top of a stack (`CardPrefetch`: the top card and the next three). Cards swiped
/// away are cancelled, which cancels their PhotoKit request. What each card shows is `CardImageLoader`'s call; this only
/// runs it and remembers the result. Unavailable cards in the window load again when the screen appears and when the
/// phone joins Wi-Fi (`watchWiFi`).
@Observable @MainActor
final class CardImages {
  private(set) var states: [String: CardImage] = [:]

  @ObservationIgnored private let source: any ThumbnailProvider
  @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
  /// The last stack shown, top first.
  @ObservationIgnored private var stack: [String] = []
  /// One check for all the prefetching cards; a yes serves a few seconds of swiping, a no is asked again.
  @ObservationIgnored private let wifi = SharedWiFiCheck { await WiFi.isAvailable() }

  init(source: any ThumbnailProvider) { self.source = source }

  func state(for id: String) -> CardImage { states[id] ?? .loading }

  /// Call whenever the stack changes (top first).
  func show(_ stack: [String]) {
    self.stack = stack
    let plan = CardPrefetch.plan(loading: Set(states.keys), stack: stack)
    for id in plan.cancel {
      tasks.removeValue(forKey: id)?.cancel()
      states[id] = nil
    }
    for id in plan.start { start(id) }
  }

  /// Loads the window's unavailable cards again.
  func retryUnavailable() {
    for id in CardPrefetch.retry(states, stack: stack) { start(id) }
  }

  func cancelAll() { show([]) }

  /// While the screen is up: follows the path, and retries the unavailable cards when the phone joins Wi-Fi.
  func watchWiFi() async {
    var was: Bool?
    for await onWiFi in WiFi.changes() {
      wifi.pathChanged(onWiFi: onWiFi)
      if onWiFi, was != true { retryUnavailable() }
      was = onWiFi
    }
  }

  private func start(_ id: String) {
    tasks[id]?.cancel()
    states[id] = .loading
    let source = source, wifi = wifi
    tasks[id] = Task { [weak self] in
      await CardImageLoader.load(id: id, request: .card, source: source,
                                 onWiFi: { await wifi.isOnWiFi() }) { state in
        self?.states[id] = state
      }
    }
  }
}

/// A card's photo: the image when there is one, a spinner while it loads or downloads, and when nothing can be shown,
/// why (never a blank).
struct CardPhoto: View {
  let image: CardImage
  /// Full screen: white text on black.
  var onDark = false

  var body: some View {
    Rectangle()
      .fill(onDark ? AnyShapeStyle(.black) : AnyShapeStyle(.rollWell))
      .overlay {
        if let cg = image.image {
          Image(decorative: cg, scale: 1)
            .resizable()
            .aspectRatio(contentMode: onDark ? .fit : .fill)
        }
      }
      .clipped()
      .overlay { status }
      .accessibilityHidden(true)
  }

  @ViewBuilder private var status: some View {
    switch image {
    case .loading:
      ProgressView().tint(onDark ? Color.white : nil)
    case .downloading(let showing):
      if showing == nil {
        VStack(spacing: 8) {
          ProgressView().tint(onDark ? Color.white : nil)
          Text("Downloading from iCloud…").font(.footnote)
        }
        .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(.rollInk2))
      } else {
        ProgressView()
          .padding(8)
          .background(.ultraThinMaterial, in: Circle())
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding(12)
      }
    case .unavailable(let why):
      VStack(spacing: 8) {
        Image(systemName: why.symbol)
          .font(.largeTitle)
        Text(why.title).font(.headline)
        Text(why.message).font(.subheadline).multilineTextAlignment(.center)
      }
      .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(.rollInk2))
      .padding(24)
    case .local, .downloaded:
      EmptyView()
    }
  }
}

private extension CardImage.Unavailable {
  var symbol: String {
    switch self {
    case .needsWiFi: "icloud.slash"
    case .failed: "photo.badge.exclamationmark"
    case .timedOut: "hourglass"
    }
  }
}
