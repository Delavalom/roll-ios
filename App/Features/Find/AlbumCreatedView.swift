import Entitlements
import Ranking
import SwiftUI

/// After Create: what went into which album, "Keep this album updated" (a saved search; new matches are offered
/// later, never added silently), "Make a video" (behind `Features.memoryVideos`), and Done.
struct AlbumCreatedView: View {
  let model: AlbumMakerModel
  let album: String
  let added: Int
  let done: () -> Void

  @State private var video: VideoRequest?

  var body: some View {
    Outcome(ring: true, title: title, message: message)
      .accessibilityIdentifier("album.created")
    if !model.added.isEmpty { ThumbFanRow(ids: Array(model.added.prefix(12))) }
    keepUpdated
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      if Features.memoryVideos, model.added.count >= 2 {
        Button("Make a video", systemImage: "film") {
          video = VideoRequest(ids: model.added, title: album)
        }
        .buttonStyle(.roll(.secondary, fullWidth: true))
        .labelStyle(.titleAndIcon)
      }
      Button("Done", action: done)
        .buttonStyle(.roll(.primary, fullWidth: true))
        .accessibilityIdentifier("album.done")
    }
    .sheet(item: $video) { MemoryVideoView(request: $0) }
  }

  private var title: String {
    guard added > 0 else { return "Already in “\(album)”" }
    return "Added \(added.formatted()) \(added == 1 ? "photo" : "photos") to “\(album)”"
  }

  private var message: String {
    added > 0 ? "The album is in Photos on this iPhone." : "Every photo you picked was already in this album."
  }

  @ViewBuilder private var keepUpdated: some View {
    switch model.keepUpdated {
    case .available:
      Button {
        Task { await model.keepAlbumUpdated() }
      } label: {
        RollNotice(symbol: "arrow.triangle.2.circlepath",
                   title: model.savingKeep ? "Saving…" : "Keep this album updated",
                   message: "When new photos match “\(model.draft.query ?? album)”, Roll shows them to you first. Nothing is added without you.")
          .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
      }
      .buttonStyle(PressScale())
      .disabled(model.savingKeep)
      .accessibilityIdentifier("album.keepUpdated")
    case .alreadyKept:
      Label("Kept up to date. New matches show up on Home for you to review.", systemImage: "checkmark")
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
    case .unavailable:
      EmptyView()
    }
    if let note = model.progressText {
      Text(note).font(Roll.Typeface.caption).foregroundStyle(.rollInk3)
    }
  }
}

/// A row of small thumbnails of what was added.
private struct ThumbFanRow: View {
  let ids: [String]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(ids, id: \.self) { id in
          Thumbnail(id: id, side: 200)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
      }
    }
    .accessibilityHidden(true)
  }
}
