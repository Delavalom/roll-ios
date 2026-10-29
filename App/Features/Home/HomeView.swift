import Overview
import Ranking
import Store
import SwiftUI
import UIKit

enum HomeRoute: Hashable {
  case duplicates(DuplicateGroup.Kind)
  case swipefile(Preset)
  case squish
  /// Swiping through an Ask answer (by answer id).
  case ask(Int)
}

/// Home is Ask Roll (spec §1): a greeting, what's worth clearing (one card per cleanup category), and a composer to
/// describe anything else. Asking turns Home into a conversation; swiping and applying are steps of it. Duplicates,
/// Squish and the preset piles open from the cards.
struct HomeView: View {
  var openSwipefiles: () -> Void = {}
  @Environment(AppModel.self) private var app

  var body: some View {
    AskHome(model: AskModel(app: app), openSwipefiles: openSwipefiles)
  }
}

private struct AskHome: View {
  @State var model: AskModel
  let openSwipefiles: () -> Void

  @Environment(AppModel.self) private var app
  @State private var path: [HomeRoute] = AskHome.initialPath
  /// A few thumbnails per category for the cards.
  @State private var fans: [CleanupCategory: [String]] = [:]
  /// The pile each answer swipes into, once made.
  @State private var piles: [Int: SwipefileRecord] = [:]
  @State private var fullScreen: String?
  /// A swipe step is being opened (its pile is being made): further taps wait.
  @State private var opening = false
  @FocusState private var composerFocused: Bool

  /// DEBUG: `-UITestOpen squish` opens Squish on launch (screenshots).
  private static var initialPath: [HomeRoute] {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if let i = arguments.firstIndex(of: "-UITestOpen"), i + 1 < arguments.count, arguments[i + 1] == "squish" {
      return [.squish]
    }
    #endif
    return []
  }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if !app.access.canRead {
              noAccess
            } else if model.isChatting {
              chat
            } else {
              intro
            }
          }
          .padding(.horizontal, Roll.Space.page)
          .padding(.bottom, Roll.Space.xl)
          .animation(Roll.Motion.ease, value: model.turns)
          Color.clear.frame(height: 1).id("end")
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.turns) {
          withAnimation(Roll.Motion.ease) { proxy.scrollTo("end", anchor: .bottom) }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if app.access.canRead { AskComposer(model: model, focused: $composerFocused) }
      }
      .overlay(alignment: .top) { topFade }
      .rollPage()
      .toolbar(.hidden, for: .navigationBar)
      .navigationTitle("Roll")
      .navigationDestination(for: HomeRoute.self, destination: destination)
      .task(id: app.libraryRevision) { await loadFans() }
      .onChange(of: path) { _, path in
        // Back from swiping: "Swipe through N" counts what's left.
        if path.isEmpty { Task { await model.refreshRemaining() } }
      }
      .fullScreenCover(item: Binding(get: { fullScreen.map(AskPhotoID.init) }, set: { fullScreen = $0?.id })) {
        FullScreenPhoto(id: $0.id)
      }
    }
  }

  /// Paper under the status bar, fading into the page, so the conversation scrolls out of sight cleanly.
  private var topFade: some View {
    VStack(spacing: 0) {
      Roll.Palette.paper.frame(height: 0).background(Roll.Palette.paper.ignoresSafeArea(edges: .top))
      LinearGradient(colors: [Roll.Palette.paper, Roll.Palette.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
        .frame(height: 18)
    }
    .allowsHitTesting(false)
  }

  private var summary: CleanupSummary { app.home.summary }

  // MARK: Intro

  @ViewBuilder private var intro: some View {
    HStack(spacing: Roll.Space.xs) {
      RollMark(size: Roll.Size.avatar)
      Text(Self.greeting()).font(Roll.Typeface.headline).foregroundStyle(.rollInk2)
    }
    .padding(.top, Roll.Space.s)
    Text("What should we clear today?")
      .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
      .padding(.top, Roll.Space.m)
    libraryLine.padding(.top, Roll.Space.xs)

    VStack(spacing: Roll.Space.s) {
      ModelStatusView()
      SquishRecoveryBanner()
    }
    .padding(.top, Roll.Space.l)

    HStack(alignment: .firstTextBaseline) {
      SectionLabel("Found in your library")
      Spacer()
      if app.home.headlineBytes > 0 {
        Text("about \(ByteFormat.short(app.home.headlineBytes)) to free")
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk3)
      }
    }
    .padding(.top, Roll.Space.l)
    .padding(.bottom, Roll.Space.s)

    VStack(spacing: Roll.Space.s) {
      ForEach(sortedCards) { card in
        NavigationLink(value: route(for: card.kind)) {
          SuggestionCard(ids: fans[card.kind] ?? [], symbol: card.symbol, title: card.kind.title,
                         detail: [card.countText, card.bytesText].compactMap { $0 }.joined(separator: " · "),
                         note: card.detail)
            .opacity(card.total.count == 0 ? 0.55 : 1)
        }
        .buttonStyle(PressScale())
        .accessibilityIdentifier("home.card.\(card.kind.rawValue)")
      }
      Button(action: openSwipefiles) {
        SuggestionCard(ids: [], symbol: "rectangle.stack", title: "Your swipefiles", detail: swipefilesText)
      }
      .buttonStyle(PressScale())
    }

    ICloudOption().padding(.top, Roll.Space.l)
    Text("Sizes are estimates. Deleted items stay in Recently Deleted for 30 days.")
      .font(Roll.Typeface.caption)
      .foregroundStyle(.rollInk3)
      .padding(.top, Roll.Space.s)
  }

  /// "29,589 photos · about 61 GB on this iPhone" (only what's known to be on the device), or what the scan is doing.
  @ViewBuilder private var libraryLine: some View {
    if let status = scanStatus {
      VStack(alignment: .leading, spacing: Roll.Space.xs) {
        StatusLine(text: status)
        if app.indexProgress.phase == .indexing, app.indexProgress.total > 0 {
          RollProgressBar(value: Double(app.indexProgress.processed) / Double(app.indexProgress.total))
        }
      }
    } else if app.home.hasLoaded, summary.library.count > 0 {
      let local = CleanupSummary.capped(summary.library.onDeviceBytes, deviceTotal: app.home.storage?.total,
                                        deviceAvailable: app.home.storage?.available)
      let count = Text(summary.library.count.formatted()).foregroundStyle(.rollInk).fontWeight(.semibold)
      Group {
        if local > 0 {
          Text("\(count) photos and videos · about \(Text(ByteFormat.short(local)).foregroundStyle(.rollInk).fontWeight(.semibold)) on\u{00A0}this\u{00A0}iPhone")
        } else {
          Text("\(count) photos and videos")
        }
      }
      .font(Roll.Typeface.subhead)
      .foregroundStyle(.rollInk2)
    }
  }

  /// What a running scan is doing, or nil when none is.
  private var scanStatus: String? {
    let progress = app.indexProgress
    switch progress.phase {
    case .syncing, .started: return "Reading your library…"
    case .indexing where progress.total > 0:
      return "Looking at \(progress.processed.formatted()) of \(progress.total.formatted()) items…"
    case .indexing: return "Reading your library…"
    case .thermalPause: return "Paused while your iPhone cools down."
    default: return nil
    }
  }

  private var swipefilesText: String {
    let piles = "\(summary.swipefileCount) \(summary.swipefileCount == 1 ? "pile" : "piles")"
    return summary.queued.count > 0 ? "\(piles) · \(summary.queued.count.formatted()) queued" : piles
  }

  static func greeting(_ date: Date = .now) -> String {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<12: "Good morning"
    case 12..<17: "Good afternoon"
    default: "Good evening"
    }
  }

  // MARK: Conversation

  @ViewBuilder private var chat: some View {
    HStack(spacing: Roll.Space.xs) {
      RollMark(size: 22)
      Text("Ask Roll").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
      Spacer()
      Button("New search", systemImage: "xmark") {
        withAnimation(Roll.Motion.ease) { model.startOver() }
      }
      .buttonStyle(.rollCircle)
    }
    .padding(.top, Roll.Space.xs)
    .padding(.bottom, Roll.Space.l)

    VStack(alignment: .leading, spacing: Roll.Space.xl) {
      ForEach(model.turns) { turn in
        switch turn {
        case .asked(_, let text):
          UserBubble(text: text)
        case .answer(let answer):
          AnswerView(answer: answer, isActionable: answer.id == model.actionableAnswer?.id, model: model,
                     swipe: swipe, open: { fullScreen = $0 })
        case .saved(_, let name):
          RollTurn {
            AnswerTitle(title: "Saved as a pile", subtitle: "“\(name)” is in Swipefiles, ready to swipe any time.")
            Button("Open Swipefiles", action: openSwipefiles).buttonStyle(.rollSecondary)
          }
        case .done(_, let count, let bytes):
          RollTurn(showsMark: false) {
            DoneRing()
            AnswerTitle(title: "About \(ByteFormat.short(bytes)) cleared",
                        subtitle: "\(count.formatted()) \(count == 1 ? "item is" : "items are") in Recently Deleted for 30 days. The space comes back once it's emptied.")
            if let next = nextCard {
              NavigationLink(value: route(for: next.kind)) {
                SuggestionCard(ids: fans[next.kind] ?? [], symbol: next.symbol, title: "Next: \(next.kind.title)",
                               detail: [next.countText, next.bytesText].compactMap { $0 }.joined(separator: " · "))
              }
              .buttonStyle(PressScale())
            }
          }
        }
      }
    }
  }

  /// Biggest first; empty categories last (still openable, quieter).
  private var sortedCards: [HomeCard] {
    let cards = app.home.cards
    return cards.filter { $0.total.count > 0 }.sorted { $0.total.bytes > $1.total.bytes }
      + cards.filter { $0.total.count == 0 }
  }

  /// The biggest category left, for "Next:".
  private var nextCard: HomeCard? {
    app.home.cards.filter { $0.total.count > 0 }.max { $0.total.onDeviceBytes < $1.total.onDeviceBytes }
  }

  private func swipe(_ answer: AskModel.Answer) {
    guard !opening else { return }
    composerFocused = false
    opening = true
    Task {
      defer { opening = false }
      guard let pile = try? await model.pile(for: answer), !path.contains(.ask(answer.id)) else { return }
      piles[answer.id] = pile
      path.append(.ask(answer.id))
    }
  }

  // MARK: Access

  @ViewBuilder private var noAccess: some View {
    if app.access == .notDetermined {
      RollEmptyState(title: "Photos access needed",
                     message: "Roll needs Photos access to find what you can clean up. Nothing leaves your phone.") {
        Button("Allow Photos access") {
          Task {
            await app.requestAccess()
            app.startIndexing()
          }
        }
        .buttonStyle(.rollPrimary)
      }
      .padding(.top, 120)
    } else {
      RollEmptyState(title: "Photos access is off",
                     message: "Turn on Photos access for Roll in Settings to find what you can clean up.") {
        Button("Open Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .buttonStyle(.rollPrimary)
      }
      .padding(.top, 120)
    }
  }

  // MARK: Routes

  private func loadFans() async {
    var out: [CleanupCategory: [String]] = [:]
    out[.duplicates] = summary.groups(.duplicates).prefix(3).map(\.keeper)
    out[.similarShots] = summary.groups(.similarShots).prefix(3).map(\.keeper)
    out[.screenshots] = (try? await app.previewCards(for: .screenshots, limit: 3)) ?? []
    out[.blurry] = (try? await app.previewCards(for: .blurry, limit: 3)) ?? []
    out[.bigVideos] = (try? await app.previewCards(for: .bigVideos, limit: 3)) ?? []
    fans = out
  }

  private func route(for category: CleanupCategory) -> HomeRoute {
    switch category {
    case .duplicates: .duplicates(.duplicates)
    case .similarShots: .duplicates(.similarShots)
    case .screenshots: .swipefile(.screenshots)
    case .blurry: .swipefile(.blurry)
    case .bigVideos: .squish
    }
  }

  @ViewBuilder private func destination(_ route: HomeRoute) -> some View {
    switch route {
    case .duplicates(let kind): DuplicatesView(kind: kind)
    case .swipefile(let preset): SwipeReviewView(swipefile: preset.swipefile(created: 0))
    case .squish: SquishView()
    case .ask(let id):
      if let answer = model.answer(id: id), let pile = piles[id] {
        let matches = answer.result?.matches ?? []
        SwipeReviewView(
          swipefile: pile, subtitle: AskModel.swipeSubtitle(answer),
          deck: app.engine.map { SearchDeck(matches: matches, engine: $0, repositories: app.repositories) },
          taken: Dictionary(matches.compactMap { m in m.created.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a }),
          onApplied: { report in
            guard report?.deleted.isEmpty == false else { return }
            Task {
              await model.applied(report)
              // Back to the conversation, where the cleared turn is waiting.
              try? await Task.sleep(for: .milliseconds(350))
              path.removeAll()
            }
          })
      } else {
        RollEmptyState(title: "This answer is gone", message: "Go back and ask again.").rollPage()
      }
    }
  }
}

private struct AskPhotoID: Identifiable {
  let id: String
}

#if DEBUG
#Preview("Home") {
  PreviewHost { HomeView() }
}

#Preview("Home, AI not ready") {
  PreviewHost(modelReady: false) { HomeView() }
}
#endif

/// "You can free about X on this iPhone", and what's in iCloud on its own line (freeing it frees iCloud space).
struct HomeHeadline: View {
  let onDevice: Int64
  let inCloud: Int64

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      if onDevice > 0 {
        // A non-breaking space keeps "49.6 MB" together when the headline wraps.
        Text("You can free about \(ByteFormat.short(onDevice).replacingOccurrences(of: " ", with: "\u{00A0}")) on this iPhone")
          .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      } else {
        Text(inCloud > 0 ? "Nothing confirmed on this iPhone yet" : "Nothing big to free yet")
          .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      }
      if inCloud > 0 {
        Text("Plus \(ByteFormat.about(inCloud)) in iCloud or not checked yet")
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Assets analysed from small previews (their originals are in iCloud), and the opt-in to use full images instead.
private struct ICloudOption: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    if app.previewCount > 0 || app.improveWithICloud {
      VStack(alignment: .leading, spacing: Roll.Space.xs) {
        RollGroup {
          Toggle(isOn: $app.improveWithICloud) {
            Text("Improve with iCloud originals").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
          }
          .tint(.rollInk)
          .padding(.horizontal, Roll.Space.m)
          .frame(minHeight: 56)
        }
        Text("\(app.previewCount.formatted()) \(app.previewCount == 1 ? "item was" : "items were") checked from a small preview because \(app.previewCount == 1 ? "its original is" : "their originals are") in iCloud. When this is on, Roll downloads them to check again, only on Wi-Fi while your iPhone is charging.")
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk3)
          .padding(.horizontal, Roll.Space.xxs)
      }
    }
  }
}
