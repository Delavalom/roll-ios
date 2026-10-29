import Overview
import SwiftUI

/// One group: the keeper is marked (tap another shot to keep it instead); "Delete N others" queues the rest.
struct DuplicateGroupView: View {
  let group: DuplicateGroup
  let model: DuplicatesModel

  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var keeper: String
  @State private var othersBytes: Int64 = 0
  @State private var committing = false

  init(group: DuplicateGroup, model: DuplicatesModel) {
    self.group = group
    self.model = model
    _keeper = State(initialValue: model.keeper(of: group))
  }

  private var others: [String] { group.members.filter { $0 != keeper } }

  /// The keeper must be a member: if the group changed under us (a rescan dropped the chosen shot), fall back to
  /// the model's pick. Without a member to keep, nothing can be queued.
  private var validKeeper: String? { group.members.contains(keeper) ? keeper : nil }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Roll.Space.s) {
        SectionLabel("\(group.members.count) shots")
          .padding(.horizontal, Roll.Space.xxs)
          .padding(.top, Roll.Space.s)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 4) {
          ForEach(group.members, id: \.self) { id in
            Button { withAnimation(Roll.Motion.quick) { keeper = id } } label: { tile(id) }
              .buttonStyle(PressScale())
              .accessibilityLabel(id == keeper ? "Kept shot" : "Shot to delete")
              .accessibilityHint(id == keeper ? "" : "Keep this one instead")
              .accessibilityAddTraits(id == keeper ? .isSelected : [])
          }
        }
        .rollCard(padding: Roll.Space.xs)
        Text("Tap a shot to keep it instead. Roll picked a favorite, or the best-looking, largest, newest one.")
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Roll.Space.xxs)
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.bottom, Roll.Space.xl)
    }
    .rollPage()
    .navigationTitle(model.kind == .duplicates ? "Duplicates" : "Similar shots")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 0) {
        Button {
          guard let keeper = validKeeper else { return }
          Task {
            await model.deleteOthers(in: group, keeping: keeper)
            committing = true
          }
        } label: {
          Text("Delete \(others.count) \(others.count == 1 ? "other" : "others") · \(ByteFormat.about(othersBytes))")
        }
        .buttonStyle(.roll(.destructive, fullWidth: true))
        .disabled(validKeeper == nil || others.isEmpty)
        if model.isQueued(group) {
          Button("Keep all") { Task { await model.keepAll(in: group) } }
            .buttonStyle(.rollText)
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.top, Roll.Space.l)
      .padding(.bottom, Roll.Space.xs)
      .background {
        LinearGradient(colors: [Roll.Palette.paper.opacity(0), Roll.Palette.paper], startPoint: .top,
                       endPoint: UnitPoint(x: 0.5, y: 0.35))
          .ignoresSafeArea(edges: .bottom)
          .allowsHitTesting(false)
      }
    }
    .task(id: keeper) { othersBytes = await model.bytes(of: others) }
    .onChange(of: group.members) { _, members in
      if !members.contains(keeper) { keeper = model.keeper(of: group) }
    }
    .sheet(isPresented: $committing, onDismiss: {
      Task {
        await model.load()
        if !app.home.summary.groups.contains(where: { $0.id == group.id }) { dismiss() }
      }
    }) {
      CommitSheet(app: app, swipefileIds: [model.swipefileId])
    }
  }

  /// A rounded square: the keeper ringed in ink with a "Keep" tag; the others, all marked to delete, with an ember dot.
  private func tile(_ id: String) -> some View {
    let kept = id == keeper
    return Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay { Thumbnail(id: id, side: 500) }
      .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
      .overlay {
        if kept {
          RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous)
            .strokeBorder(.rollInk, lineWidth: 3)
        }
      }
      .overlay(alignment: .topLeading) {
        if kept {
          VerdictTag(title: "Keep", color: .rollKeep)
            .padding(Roll.Space.xs)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
          Circle()
            .fill(.rollEmber)
            .frame(width: 10, height: 10)
            .padding(2)
            .background(.rollCard, in: Circle())
            .padding(Roll.Space.s)
        }
      }
      .opacity(kept ? 1 : 0.85)
      .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
  }
}
