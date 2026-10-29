import Library
import Ranking
import Store
import SwiftUI

/// One swipe card (spec §5), in the deck style: a white card holding the photo, with its about-size and kind
/// underneath and, while dragging, a verdict tag saying what letting go will do. With nothing on screen
/// (`CardGate.skipOnly`) a swipe only skips, and the tag says so.
struct CardView: View {
  let card: SwipefileEngine.Candidate
  /// The best image on the device, else a Wi-Fi download, else why there's none (`CardImageLoader`).
  var image: CardImage = .loading
  var offset: CGSize = .zero
  var actionTitle = "Delete"
  /// When the photo was taken, if known ("Mar 2024").
  var taken: Double?

  var body: some View {
    VStack(spacing: 0) {
      CardPhoto(image: image)
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.photo, style: .continuous))
        .overlay(alignment: tagAlignment) { tag }
      footer
    }
    .padding(6)
    .background(.rollCard, in: RoundedRectangle(cornerRadius: Roll.Radius.deck, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Roll.Radius.deck, style: .continuous)
        .strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth)
    }
    .rollShadow(lifted: offset != .zero)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  private var isVideo: Bool { card.mediaType == Preset.videoMediaType }

  private var footer: some View {
    HStack(spacing: 6) {
      Text(ByteFormat.about(card.estBytes)).font(Roll.Typeface.figure).foregroundStyle(.rollInk)
      Text("· \(isVideo ? "video" : "photo")\(card.lowConfidence ? " · weaker match" : "")")
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
      Spacer(minLength: 4)
      if let taken {
        Text(Date(timeIntervalSince1970: taken).formatted(.dateTime.month(.abbreviated).year()))
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk3)
      }
    }
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.top, 10)
    .padding(.bottom, 6)
  }

  /// The verdict the drag points at, fading in past a third of the commit distance.
  @ViewBuilder private var tag: some View {
    let (text, color, strength) = verdictHint
    if strength > 0 {
      VerdictTag(title: text, color: color)
        .padding(14)
        .scaleEffect(0.9 + 0.1 * strength)
        .opacity(strength)
    }
  }

  private var tagAlignment: Alignment {
    if -offset.height > abs(offset.width) { return .bottom }
    return offset.width < 0 ? .topTrailing : .topLeading
  }

  private var verdictHint: (String, Color, Double) {
    let threshold = SwipeReviewView.commitDistance
    func strength(_ distance: CGFloat) -> Double { Double(min(1, max(0, (distance - threshold / 3) / (threshold * 2 / 3)))) }
    switch image.gate {
    case .decide: break
    case .wait: return ("", .clear, 0)
    case .skipOnly: return ("Skip", .rollInk3, strength(max(abs(offset.width), -offset.height)))
    }
    if -offset.height > abs(offset.width), offset.height < 0 { return ("Album", .rollAlbum, strength(-offset.height)) }
    if offset.width < 0 { return (actionTitle, .rollEmber, strength(-offset.width)) }
    return ("Keep", .rollKeep, strength(offset.width))
  }

  private var accessibilityText: String {
    let base = "\(isVideo ? "Video" : "Photo"), \(ByteFormat.about(card.estBytes))\(card.lowConfidence ? ", weaker match" : "")"
    switch image {
    case .loading: return base + ", loading"
    case .downloading(.none): return base + ", downloading from iCloud"
    case .unavailable(let why): return "\(base). \(why.title). \(why.message)"
    default: return base
    }
  }
}

/// Tap on a card: the photo full screen. Shows the best local image at once and, on Wi-Fi, replaces a small one with a
/// 2000 px download (`CardImageRequest.fullScreen`); closing it cancels the request.
struct FullScreenPhoto: View {
  let id: String
  @Environment(\.dismiss) private var dismiss
  @Environment(\.thumbnails) private var provider
  @State private var image: CardImage = .loading

  var body: some View {
    CardPhoto(image: image, onDark: true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.black)
      .task(id: id) {
        image = .loading
        await CardImageLoader.load(id: id, request: .fullScreen, source: provider,
                                   onWiFi: { await WiFi.isAvailable() }) { image = $0 }
      }
      .overlay(alignment: .topTrailing) {
        Button("Close", systemImage: "xmark") { dismiss() }
          .buttonStyle(.rollCircle)
          .padding()
      }
      .onTapGesture { dismiss() }
  }
}
