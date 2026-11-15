import Ranking
import SwiftUI

/// Home's living-album offers: "12 new photos for Soccer", one card per kept album with new matches. Tapping opens the
/// review grid; nothing is added until the person says so there.
struct LivingAlbumCards: View {
  let open: (String) -> Void
  @Environment(AppModel.self) private var app

  var body: some View {
    ForEach(app.living.inbox.items) { item in
      Button { open(item.savedSearchId) } label: {
        SuggestionCard(ids: Array(item.ids.prefix(3)), symbol: "rectangle.stack.badge.plus", title: item.title,
                       detail: "Review and add to the album", note: "Matched “\(item.query)” on this iPhone")
      }
      .buttonStyle(PressScale())
      .accessibilityIdentifier("home.living.\(item.albumName)")
    }
  }
}
