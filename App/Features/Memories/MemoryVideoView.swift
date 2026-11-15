import AVKit
import SwiftUI

/// The memory video sheet: rendering with progress and Cancel, then a preview, Share and Save to Photos.
struct MemoryVideoView: View {
  @State private var model: MemoryVideoModel
  @State private var player: AVPlayer?
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss

  init(request: VideoRequest) {
    _model = State(initialValue: MemoryVideoModel(request: request))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Roll.Space.l) { content }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Roll.Space.page)
          .padding(.top, Roll.Space.xs)
          .padding(.bottom, Roll.Space.xl)
      }
      .rollPage()
      .navigationTitle(model.request.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(isWorking ? "Cancel" : "Done") {
            if isWorking { model.cancel() }
            dismiss()
          }
        }
      }
    }
    .presentationCornerRadius(Roll.Radius.panel)
    .task { model.start(app: app) }
    .onDisappear {
      player?.pause()
      model.close()
    }
  }

  private var isWorking: Bool {
    switch model.phase {
    case .planning, .rendering: true
    default: false
    }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .planning:
      working(progress: nil)
    case .rendering(let progress):
      working(progress: progress)
    case .ready(let url):
      ready(url)
    case .failed(let text):
      Outcome(symbol: "film", title: "No video this time", message: text)
    case .cancelled:
      Outcome(symbol: "film", title: "Stopped", message: "Nothing was saved.")
    }
  }

  @ViewBuilder private func working(progress: Double?) -> some View {
    HStack(spacing: Roll.Space.s) {
      RollMark(size: 40, busy: true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Making your video").rollTitle()
        Text(model.shots > 0 ? "\(model.shots) shots, about \(Int(model.seconds.rounded())) seconds" : "Picking the shots…")
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
      }
    }
    if let progress {
      RollProgressBar(value: progress)
      Text("\(Int(progress * 100))%").font(Roll.Typeface.figure).foregroundStyle(.rollInk2)
    }
    Text("Made on this iPhone. Keep Roll open until it's done.")
      .font(Roll.Typeface.caption)
      .foregroundStyle(.rollInk3)
    Button("Cancel") { model.cancel() }.buttonStyle(.rollSecondary)
  }

  @ViewBuilder private func ready(_ url: URL) -> some View {
    VideoPlayer(player: player)
      .aspectRatio(9 / 16, contentMode: .fit)
      .frame(maxHeight: 460)
      .frame(maxWidth: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.photo, style: .continuous))
      .onAppear {
        if player == nil { player = AVPlayer(url: url) }
        player?.play()
      }
    HStack(spacing: Roll.Space.xs) {
      ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        .buttonStyle(.rollSecondary)
      Button(saveTitle) { Task { await model.saveToPhotos() } }
        .buttonStyle(.rollPrimary)
        .disabled(model.save == .saving || model.save == .saved)
    }
    if case .failed(let text) = model.save {
      Text(text).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2)
    }
    Text("Silent, 1080 × 1920. This copy goes away when you close; saved videos stay in Photos.")
      .font(Roll.Typeface.caption)
      .foregroundStyle(.rollInk3)
  }

  private var saveTitle: String {
    switch model.save {
    case .saving: "Saving…"
    case .saved: "Saved to Photos"
    default: "Save to Photos"
    }
  }
}
