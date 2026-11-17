import Entitlements
import Ranking
import SwiftUI

/// "Make album": the album's name, a grid of the answer's photos with the strong matches already selected (tap to
/// toggle, select or deselect all, a running count), then Create. Once created, the same screen says what happened
/// and offers "Keep this album updated" and "Make a video". A living album's offer opens here too, with its name fixed.
struct AlbumMakerView: View {
  @State var model: AlbumMakerModel
  var done: () -> Void = {}

  @Environment(AppModel.self) private var app
  @State private var showingPaywall = false
  @FocusState private var nameFocused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Roll.Space.l) {
        if case .created(let album, let added) = model.phase {
          AlbumCreatedView(model: model, album: album, added: added, done: done)
        } else {
          editor
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Roll.Space.page)
      .padding(.top, Roll.Space.xs)
      .padding(.bottom, Roll.Space.xl)
    }
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom) { footer }
    .rollPage()
    .navigationTitle(model.isOffer ? "New photos" : "Make album")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showingPaywall, onDismiss: { Task { await model.recheck() } }) {
      PaywallView(provider: app.entitlements, pitch: app.home.paywallPitch) { showingPaywall = false }
    }
  }

  // MARK: Editing

  @ViewBuilder private var editor: some View {
    if model.isOffer {
      AnswerTitle(title: "New photos for \(model.selection.name)",
                  subtitle: "Roll found these after reading new photos. Leave out any that don't belong.")
    } else {
      VStack(alignment: .leading, spacing: Roll.Space.xs) {
        SectionLabel("Album name")
        TextField("Album name", text: $model.selection.name)
          .font(Roll.Typeface.headline)
          .foregroundStyle(.rollInk)
          .tint(.rollEmber)
          .submitLabel(.done)
          .focused($nameFocused)
          .padding(.horizontal, Roll.Space.m)
          .frame(minHeight: Roll.Size.control + 8)
          .background(.rollCard, in: RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous)
              .strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth)
          }
          .accessibilityIdentifier("album.name")
      }
    }
    HStack(alignment: .firstTextBaseline) {
      Text("\(Text(model.selection.count.formatted()).foregroundStyle(.rollInk).fontWeight(.semibold)) of \(model.selection.ids.count.formatted()) selected")
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .contentTransition(.numericText())
        .accessibilityIdentifier("album.count")
      Spacer()
      Button(model.selection.allSelected ? "Deselect all" : "Select all") {
        withAnimation(Roll.Motion.quick) {
          if model.selection.allSelected { model.selection.deselectAll() } else { model.selection.selectAll() }
        }
      }
      .buttonStyle(.rollText)
      .accessibilityIdentifier("album.toggleAll")
    }
    SelectableGrid(ids: model.selection.ids, isSelected: model.selection.isSelected,
                   toggle: { model.selection.toggle($0) },
                   dragBegan: { model.selection.beginDrag(at: $0) },
                   dragMoved: { model.selection.continueDrag(to: $0) },
                   dragEnded: { model.selection.endDrag() })
    Text("Roll adds the photos to an album in Photos, on this iPhone. Nothing is moved or deleted.")
      .font(Roll.Typeface.caption)
      .foregroundStyle(.rollInk3)
  }

  // MARK: Footer

  @ViewBuilder private var footer: some View {
    switch model.phase {
    case .created:
      EmptyView()
    case .quota(let blocked, let allowed):
      VStack(alignment: .leading, spacing: Roll.Space.s) {
        RollNotice(symbol: "lock.fill",
                   title: "\(blocked.formatted()) more \(blocked == 1 ? "photo needs" : "photos need") Roll Pro",
                   message: "The first \(FreeQuota.limit) changes are free, and each photo added to an album counts as one. Unlock Pro to add the rest.",
                   action: ("Unlock Roll Pro", { showingPaywall = true }))
        HStack(spacing: Roll.Space.xs) {
          if allowed > 0 {
            Button("Add \(allowed.formatted()) for now") { Task { await model.apply() } }.buttonStyle(.rollPrimary)
          }
          Button("Back") { model.backToEditing() }.buttonStyle(.rollSecondary)
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.vertical, Roll.Space.s)
      .background(Roll.Palette.paper.ignoresSafeArea(edges: .bottom))
    default:
      VStack(spacing: Roll.Space.xs) {
        if case .failed(let text) = model.phase {
          Text(text).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2).frame(maxWidth: .infinity, alignment: .leading)
        }
        if let progress = model.progressText {
          StatusLine(text: progress)
        }
        Button {
          nameFocused = false
          Task { await model.create() }
        } label: {
          Text(model.isBusy ? "Adding…" : model.selection.createTitle)
        }
        .buttonStyle(.roll(.primary, fullWidth: true))
        .disabled(!model.selection.canCreate || model.isBusy)
        .accessibilityIdentifier("album.create")
        if model.isOffer {
          Button("Not now") {
            Task {
              await model.dismissOffer()
              done()
            }
          }
          .buttonStyle(.rollText)
          .disabled(model.isBusy)
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.vertical, Roll.Space.s)
      .background(Roll.Palette.paper.ignoresSafeArea(edges: .bottom))
    }
  }
}
