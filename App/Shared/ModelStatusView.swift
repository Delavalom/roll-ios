import SwiftUI

/// The on-device model's state as one notice card: download progress, preparing search (first launch after an install
/// or update), waiting for Wi-Fi (with a mobile-data choice), or "not ready" with the reason and a retry. While ready,
/// nothing, or a low-storage note if preparing had to stop.
struct ModelStatusView: View {
  @Environment(AppModel.self) private var app

  private static let stillWorks = "Describing piles is off for now. Screenshots, blurry photos, big videos and duplicates still work."

  var body: some View {
    switch app.modelState {
    case .ready:
      if app.searchStorageLow {
        RollNotice(symbol: "externaldrive", title: "Storage is low",
                   message: "Search works, but it starts slower until about 3.5 GB is free.")
      }
    case .preparing(let done, let total):
      ModelPreparingCard(done: done, total: total, note: "Takes a few minutes after installing or updating Roll. \(Self.stillWorks)")
    case .loading(let progress):
      ModelLoadingCard(progress: progress)
    case .waiting(let reason, let total):
      let size = total.map { " (\(ByteFormat.about($0)))" } ?? ""
      switch reason {
      case .wifi:
        RollNotice(symbol: "wifi", title: "Waiting for Wi-Fi",
                   message: "The on-device AI\(size) downloads on Wi-Fi and starts by itself. \(Self.stillWorks)",
                   action: (title: "Use mobile data", perform: { app.downloadModelAnyway() }))
      case .lowDataMode:
        RollNotice(symbol: "wifi", title: "Low Data Mode is on",
                   message: "The on-device AI\(size) downloads once Low Data Mode is off. \(Self.stillWorks)",
                   action: (title: "Download anyway", perform: { app.downloadModelAnyway() }))
      }
    case .unavailable(let issue):
      switch issue {
      case .notEnoughSpace(let required):
        RollNotice(symbol: "externaldrive", title: "Not enough free space",
                   message: "The on-device AI needs \(ByteFormat.about(required)) free to download and set up. \(Self.stillWorks)",
                   action: (title: "Retry", perform: { app.loadModel() }))
      case .failed:
        RollNotice(symbol: "sparkles", title: "On-device AI not ready",
                   message: "Its download or setup didn't finish. \(Self.stillWorks)",
                   action: (title: "Retry", perform: { app.loadModel() }))
      case .notStarted, .notPublished:
        RollNotice(symbol: "sparkles", title: "On-device AI not ready", message: Self.stillWorks,
                   action: (title: "Retry", perform: { app.loadModel() }))
      }
    }
  }
}

/// The download (or the setup after it) as a notice card: the busy mark, what's happening, and the progress bar.
private struct ModelLoadingCard: View {
  let progress: ModelProgress?

  var body: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      RollMark(size: 36, busy: true)
      VStack(alignment: .leading, spacing: 4) {
        if let progress {
          Text("Downloading the on-device AI").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
          Text(progress.text)
            .font(Roll.Typeface.figure)
            .foregroundStyle(.rollInk2)
            .contentTransition(.numericText())
          RollProgressBar(value: progress.fraction).padding(.top, 6)
        } else {
          Text("Getting the on-device AI ready").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
          Text("It runs on this iPhone. Nothing about your photos leaves your phone.")
            .font(Roll.Typeface.subhead)
            .foregroundStyle(.rollInk2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .rollCard()
    .accessibilityElement(children: .combine)
  }
}

/// Preparing search on first launch after an install or update: the busy mark, the count, and the progress bar.
private struct ModelPreparingCard: View {
  let done: Int
  let total: Int
  let note: String

  var body: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      RollMark(size: 36, busy: true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Preparing search, first time only").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
        Text("\(done) of \(total)")
          .font(Roll.Typeface.figure)
          .foregroundStyle(.rollInk2)
          .contentTransition(.numericText())
        RollProgressBar(value: Double(done) / Double(max(total, 1))).padding(.vertical, 6)
        Text(note)
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .rollCard()
    .accessibilityElement(children: .combine)
  }
}
