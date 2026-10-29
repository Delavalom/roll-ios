import Overview
import SwiftUI

/// Duplicate (or similar-shot) groups as cards of thumbnails; a group opens `DuplicateGroupView`.
struct DuplicatesView: View {
  let kind: DuplicateGroup.Kind
  @Environment(AppModel.self) private var app

  var body: some View {
    DuplicatesList(model: DuplicatesModel(app: app, kind: kind))
  }
}

private struct DuplicatesList: View {
  @State var model: DuplicatesModel
  @Environment(AppModel.self) private var app
  @State private var committing = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if model.groups.isEmpty {
          RollEmptyState(title: app.home.hasLoaded ? "No \(model.title.lowercased()) found" : "Looking…",
                         message: "Roll checks new photos as it indexes them.", busy: !app.home.hasLoaded)
            .padding(.top, 80)
        } else {
          SectionLabel("\(model.groups.count.formatted()) \(model.groups.count == 1 ? "group" : "groups")")
            .padding(.horizontal, Roll.Space.xxs)
            .padding(.top, Roll.Space.s)
            .padding(.bottom, Roll.Space.s)
          LazyVStack(spacing: Roll.Space.s) {
            ForEach(model.groups) { group in
              NavigationLink {
                DuplicateGroupView(group: group, model: model)
              } label: {
                GroupCard(group: group, keeper: model.keeper(of: group), queued: model.isQueued(group))
              }
              .buttonStyle(PressScale())
              .accessibilityIdentifier("duplicates.group")
            }
          }
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.bottom, Roll.Space.xl)
    }
    .rollPage()
    .navigationTitle(model.title)
    .safeAreaInset(edge: .bottom) {
      if model.queuedCount > 0 {
        Button {
          committing = true
        } label: {
          Text("Review & apply · \(model.queuedCount.formatted()) queued")
        }
        .buttonStyle(.roll(.primary, fullWidth: true))
        .padding(.horizontal, Roll.Space.page)
        .padding(.top, Roll.Space.l)
        .padding(.bottom, Roll.Space.xs)
        .background { PaperFade() }
      }
    }
    .task { await model.load() }
    .sheet(isPresented: $committing, onDismiss: { Task { await model.load() } }) {
      CommitSheet(app: app, swipefileIds: [model.swipefileId])
    }
  }
}

/// Paper fading in under the bottom bar, so the cards scroll out of sight under it.
private struct PaperFade: View {
  var body: some View {
    LinearGradient(colors: [Roll.Palette.paper.opacity(0), Roll.Palette.paper], startPoint: .top,
                   endPoint: UnitPoint(x: 0.5, y: 0.45))
      .ignoresSafeArea(edges: .bottom)
      .allowsHitTesting(false)
  }
}

/// One group on a card: its first shots as rounded squares (the keeper with a keep dot; the others with an ember dot
/// once queued), then the count and size.
private struct GroupCard: View {
  let group: DuplicateGroup
  /// The user's pick when the group is queued, else the default (`DuplicatesModel.keeper(of:)`).
  let keeper: String
  let queued: Bool

  private static let shown = 4
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: GroupCard.shown)

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.s) {
      LazyVGrid(columns: columns, spacing: 4) {
        let visible = Array(group.members.prefix(Self.shown))
        ForEach(Array(visible.enumerated()), id: \.element) { index, id in
          Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { Thumbnail(id: id, side: 200) }
            .overlay {
              let more = group.members.count - Self.shown
              if index == Self.shown - 1, more > 0 {
                ZStack {
                  Roll.Palette.ink.opacity(0.55)
                  Text("+\(more.formatted())").font(Roll.Typeface.headline.monospacedDigit()).foregroundStyle(.rollOnInk)
                }
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
              if id == keeper {
                Dot(color: .rollKeep)
              } else if queued {
                Dot(color: .rollEmber)
              }
            }
        }
      }
      HStack(spacing: Roll.Space.xs) {
        Text("\(group.members.count) shots · \(ByteFormat.about(group.reclaimableBytes))")
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
        if queued {
          HStack(spacing: 6) {
            Circle().fill(.rollEmber).frame(width: 6, height: 6)
            Text("Queued").font(Roll.Typeface.label).foregroundStyle(.rollInk)
          }
        }
        Spacer(minLength: Roll.Space.xs)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.bold))
          .foregroundStyle(.rollInk3)
      }
    }
    .rollCard(padding: Roll.Space.s)
    .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(group.members.count) shots, \(ByteFormat.about(group.reclaimableBytes))\(queued ? ", queued" : "")")
  }
}

/// A small dot on a thumbnail's corner, ringed in card white so it reads on any photo.
private struct Dot: View {
  let color: Color

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 10, height: 10)
      .padding(2)
      .background(.rollCard, in: Circle())
      .padding(5)
  }
}

#if DEBUG
#Preview("Duplicates") {
  PreviewHost { NavigationStack { DuplicatesView(kind: .duplicates) } }
}
#endif
