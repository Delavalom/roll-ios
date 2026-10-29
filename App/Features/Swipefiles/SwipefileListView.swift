import Ranking
import Store
import SwiftUI

/// Presets plus custom swipefiles; "New swipefile" adds one. The Private preset needs Face ID first (on an iPhone
/// with no passcode it opens directly, with a note saying how to lock it).
struct SwipefileListView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    SwipefileList(model: SwipefileListModel(app: app))
  }
}

private struct SwipefileList: View {
  @State var model: SwipefileListModel
  @State private var path: [SwipefileRecord] = []
  @State private var creating = false
  /// A few thumbnails per pile for its card (never the Private pile's).
  @State private var fans: [String: [String]] = [:]
  /// What each pile has queued: the count and, for piles that delete, about how much that is.
  @State private var queued: [String: (count: Int, bytes: Int64)] = [:]
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack(path: $path) {
      // A List (styled as cards on paper) keeps swipe-to-delete on your own piles.
      List {
        Group {
          ModelStatusView()
          SectionLabel("Presets").padding(.top, Roll.Space.s)
          ForEach(model.presets) { row($0) }
          SectionLabel("Yours").padding(.top, Roll.Space.l)
          ForEach(model.custom) { swipefile in
            row(swipefile)
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(swipefile) }
                  .tint(.rollEmber)
              }
              .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(swipefile) }
              }
          }
          Button("New swipefile", systemImage: "plus") { creating = true }
            .buttonStyle(.roll(.secondary, fullWidth: true))
            .padding(.top, Roll.Space.xxs)
            .padding(.bottom, Roll.Space.xl)
        }
        .listRowInsets(EdgeInsets(top: Roll.Space.xxs + 2, leading: Roll.Space.page, bottom: Roll.Space.xxs + 2,
                                  trailing: Roll.Space.page))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
      .listStyle(.plain)
      .rollPage()
      .navigationTitle("Swipefiles")
      .toolbar {
        Button("New swipefile", systemImage: "plus") { creating = true }
      }
      .navigationDestination(for: SwipefileRecord.self) { SwipeReviewView(swipefile: $0) }
      .task { await model.load() }
      .task(id: loadKey) { await loadCards() }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .active:
          model.refreshLock()
        case .background:
          // Leaving the app locks the Private pile again: pop it (and anything above it), so coming back asks first.
          if let index = path.firstIndex(where: model.needsUnlock) { path.removeSubrange(index...) }
        default:
          break
        }
      }
      .sheet(isPresented: $creating) {
        NewSwipefileView { created in
          Task {
            await model.load()
            path.append(created)
          }
        }
      }
      .alert("Something went wrong", isPresented: Binding(get: { model.message != nil },
                                                          set: { if !$0 { model.message = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.message ?? "")
      }
    }
  }

  private func row(_ swipefile: SwipefileRecord) -> some View {
    Button {
      open(swipefile)
    } label: {
      PileCard(ids: fans[swipefile.id] ?? [], symbol: Self.symbol(swipefile), title: swipefile.name,
               detail: model.subtitle(swipefile), note: queuedLine(swipefile),
               locked: model.needsUnlock(swipefile))
    }
    .buttonStyle(PressScale())
  }

  /// "12 queued · about 48 MB" (the size only for piles that delete), or nil with nothing queued.
  private func queuedLine(_ swipefile: SwipefileRecord) -> String? {
    // Nothing about a locked pile's contents shows before Face ID.
    guard !model.needsUnlock(swipefile), let queued = queued[swipefile.id], queued.count > 0 else { return nil }
    let count = "\(queued.count.formatted()) queued"
    guard swipefile.action == .delete, queued.bytes > 0 else { return count }
    return "\(count) · \(ByteFormat.about(queued.bytes))"
  }

  private static func symbol(_ swipefile: SwipefileRecord) -> String {
    switch Preset(swipefile: swipefile) {
    case .screenshots: "camera.viewfinder"
    case .blurry: "camera.aperture"
    case .memes: "face.smiling"
    case .receipts: "doc.text"
    case .privateStuff: "lock"
    case .bigVideos: "film"
    case nil: "rectangle.stack"
    }
  }

  private func delete(_ swipefile: SwipefileRecord) {
    Task { await model.delete(swipefile) }
  }

  private func open(_ swipefile: SwipefileRecord) {
    guard model.needsUnlock(swipefile) else {
      path.append(swipefile)
      return
    }
    Task {
      if await model.unlock() { path.append(swipefile) }
    }
  }

  // MARK: Cards

  /// Reloads the cards' thumbnails and queued lines when the piles or the library change, and on the way back from
  /// a pile (its queue may have changed).
  private var loadKey: String {
    let ids = (model.presets + model.custom).map(\.id).joined(separator: ",")
    return "\(app.libraryRevision)|\(path.isEmpty)|\(ids)"
  }

  private func loadCards() async {
    guard path.isEmpty else { return }
    let repositories = app.repositories
    var fans: [String: [String]] = [:]
    var queued: [String: (count: Int, bytes: Int64)] = [:]
    for swipefile in model.presets + model.custom {
      if let ids = try? await repositories.queued(for: swipefile.id).map(\.assetId), !ids.isEmpty {
        let records = (try? await repositories.assets(ids: ids)) ?? []
        queued[swipefile.id] = (ids.count, records.filter { !$0.deleted }.reduce(0) { $0 + $1.estBytes })
      }
      if Task.isCancelled { return }
      switch Preset(swipefile: swipefile) {
      case .privateStuff:
        continue
      case let preset?:
        fans[swipefile.id] = (try? await app.previewCards(for: preset, limit: 3)) ?? []
      case nil:
        fans[swipefile.id] = Array(swipefile.examples.prefix(3))
      }
    }
    if Task.isCancelled { return }
    self.fans = fans
    self.queued = queued
  }
}

/// One pile as a card: its thumbnails fanned out (or its symbol), the name, its line, what's queued, and a lock
/// while it needs Face ID.
private struct PileCard: View {
  let ids: [String]
  let symbol: String
  let title: String
  let detail: String
  var note: String?
  var locked = false

  var body: some View {
    HStack(spacing: Roll.Space.s) {
      if ids.isEmpty {
        RollIconTile(symbol: symbol).frame(width: 46 * 1.9, height: 54)
      } else {
        ThumbFan(ids: ids)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
        Text(detail)
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
          .lineLimit(2)
        if let note {
          Text(note).font(Roll.Typeface.caption.monospacedDigit()).foregroundStyle(.rollInk3)
        }
      }
      Spacer(minLength: Roll.Space.xs)
      if locked {
        Image(systemName: "lock.fill")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.rollInk2)
          .accessibilityLabel("Locked")
      }
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.bold))
        .foregroundStyle(.rollInk3)
        .accessibilityHidden(true)
    }
    .rollCard(padding: Roll.Space.s)
    .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

extension SwipefileRecord: @retroactive Hashable {
  public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#if DEBUG
#Preview {
  PreviewHost { SwipefileListView() }
}
#endif
