import Ranking
import SwiftUI

/// What a memory video is made from: photos and the title they came under.
struct VideoRequest: Identifiable, Equatable {
  let id = UUID()
  let ids: [String]
  let title: String
}

/// The photos of a found answer: event sections (place, dates, count, "rest of this day", Make album) or one grid,
/// the folded weaker matches, and notes for photos a filter couldn't test. While picking "more like these", taps pick
/// instead of opening.
struct FindResultBody: View {
  let answer: AskModel.Answer
  let find: FindAnswer
  let model: AskModel
  let open: (String) -> Void
  let makeAlbum: (Int) -> Void
  let makeVideo: (VideoRequest) -> Void

  /// Sections before "Show N more events".
  static let sectionPreview = 4
  /// Photos per section before "Show all".
  static let sectionPhotos = 6

  private var picking: Bool { model.picking == answer.id }

  var body: some View {
    if find.sections.isEmpty {
      let shown = answer.expanded ? find.strong : Array(find.strong.prefix(AskModel.previewCount))
      grid(shown)
      let hidden = find.strong.count - shown.count
      if hidden > 0 {
        Button("+ \(hidden.formatted()) more") { withAnimation(Roll.Motion.ease) { model.expand(answer.id) } }
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
      }
    } else {
      let sections = answer.expanded ? find.sections : Array(find.sections.prefix(Self.sectionPreview))
      ForEach(sections) { section in
        SectionBlock(section: section, answer: answer, model: model, picking: picking, grid: grid,
                     makeAlbum: { makeAlbum(model.albumDraft(for: answer, section: section)) },
                     makeVideo: { makeVideo(VideoRequest(ids: section.ids + section.rest, title: section.title)) })
      }
      let more = find.sections.count - sections.count
      if more > 0 {
        Button("Show \(more.formatted()) more \(more == 1 ? "event" : "events")") {
          withAnimation(Roll.Motion.ease) { model.expand(answer.id) }
        }
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
      }
    }
    if let weaker = find.weakerText {
      Button {
        withAnimation(Roll.Motion.ease) { model.toggleWeaker(answer.id) }
      } label: {
        Label(weaker, systemImage: answer.showsWeaker ? "chevron.up" : "chevron.down")
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
      }
      .accessibilityIdentifier("ask.weaker")
      if answer.showsWeaker { grid(find.weaker) }
    }
    ForEach(find.notes, id: \.self) { note in
      Label(note, systemImage: "info.circle")
        .font(Roll.Typeface.caption)
        .foregroundStyle(.rollInk3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private func grid(_ ids: [String]) -> some View {
    if picking {
      ResultGrid(ids: ids, open: model.togglePick, isPicked: model.pick.contains)
    } else {
      ResultGrid(ids: ids, open: open)
    }
  }
}

/// One event of an answer: "Lisbon · Jun 3–7, 2024", "8 photos", its photos, the rest of the event, and its actions.
private struct SectionBlock<Grid: View>: View {
  let section: FindAnswer.Section
  let answer: AskModel.Answer
  let model: AskModel
  let picking: Bool
  let grid: ([String]) -> Grid
  let makeAlbum: () -> Void
  let makeVideo: () -> Void

  @State private var showsAll = false
  @State private var showsRest = false

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      VStack(alignment: .leading, spacing: 2) {
        Text(section.title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Text(section.countText).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2)
      }
      let shown = showsAll ? section.ids : Array(section.ids.prefix(FindResultBody.sectionPhotos))
      grid(shown)
      HStack(spacing: Roll.Space.s) {
        if shown.count < section.ids.count {
          Button("Show all \(section.ids.count.formatted())") { withAnimation(Roll.Motion.ease) { showsAll = true } }
        }
        if let rest = section.restText {
          Button(showsRest ? "Hide the rest of this \(section.restNoun)" : rest) {
            withAnimation(Roll.Motion.ease) { showsRest.toggle() }
          }
        }
      }
      .font(Roll.Typeface.subhead)
      .foregroundStyle(.rollInk2)
      if showsRest { grid(section.rest).opacity(0.85) }
      if !picking {
        HStack(spacing: Roll.Space.xs) {
          Button("Make album", systemImage: "rectangle.stack.badge.plus", action: makeAlbum)
            .buttonStyle(.rollPrimary)
            .accessibilityIdentifier("section.makeAlbum")
          if Features.memoryVideos {
            Button("Make a video", systemImage: "film", action: makeVideo).buttonStyle(.rollSecondary)
          }
        }
        .labelStyle(.titleOnly)
        .padding(.top, 2)
      }
    }
    .padding(.top, Roll.Space.xs)
  }
}

/// "Pick up to 3 photos" / "More like these 2", while picking seeds on an answer.
struct SeedPickBar: View {
  let model: AskModel

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      Text("Tap up to \(SeedPick.limit) photos that look right. Roll finds more like them.")
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Roll.Space.xs) {
        Button(model.pick.actionTitle) { model.searchPicked() }
          .buttonStyle(.rollPrimary)
          .disabled(!model.pick.canSearch)
          .accessibilityIdentifier("ask.searchPicked")
        Button("Cancel") { withAnimation(Roll.Motion.ease) { model.cancelPicking() } }
          .buttonStyle(.rollSecondary)
      }
    }
  }
}
