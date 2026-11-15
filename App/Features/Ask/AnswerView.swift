import Ranking
import SwiftUI

/// One answer: what Roll did (counted and measured), what it found (event sections or a grid, weaker matches folded),
/// a reply built from the dates, and, on the actionable answer (the last one that came back), what to do next: Make
/// album, swipe through it as a pile, save the pile, refine, or pick photos for "more like these". A refused query
/// says so and shows only the closest few.
struct AnswerView: View {
  let answer: AskModel.Answer
  let isActionable: Bool
  let model: AskModel
  let swipe: (AskModel.Answer) -> Void
  let open: (String) -> Void
  var makeAlbum: (Int) -> Void = { _ in }
  var makeVideo: (VideoRequest) -> Void = { _ in }

  @State private var saving = false

  var body: some View {
    RollTurn(busy: answer.result == nil && answer.failure == nil) {
      if let failure = answer.failure {
        AnswerTitle(title: "That search didn't run", subtitle: failure)
      } else if let result = answer.result {
        StatusLine(text: AskModel.elapsed(result), done: true)
        if let find = answer.find, find.nothingFound, !find.closest.isEmpty {
          closest(find)
        } else if result.matches.isEmpty {
          nothing(result)
        } else {
          found(result)
        }
      } else {
        StatusLine(text: "Comparing with your library on this iPhone")
      }
    }
  }

  @ViewBuilder private func nothing(_ result: PhotoSearch.Result) -> some View {
    // No photo has been read by the on-device AI yet (the first scan, or the switch to a new model).
    if result.compared == 0 {
      AnswerTitle(title: "Nothing to compare yet",
                  subtitle: "Roll is still reading your library on this iPhone. Ask again once it's done.")
    } else {
      AnswerTitle(title: "Nothing stood out",
                  subtitle: answer.isRefinement ? "None of the matches fit that. Change the filters below."
                    : "Try what's in the photo, like “receipts” or “a beach trip”.")
      if let weaker = answer.find?.weakerText {
        Text(weaker).font(Roll.Typeface.subhead).foregroundStyle(.rollInk3)
      }
      // A refinement that empties the answer can always be undone from here.
      if isActionable, answer.isRefinement { RefineChips(answer: answer, model: model) }
    }
  }

  /// The query was refused: an honest low-confidence answer with at most 12 closest photos.
  @ViewBuilder private func closest(_ find: FindAnswer) -> some View {
    AnswerTitle(title: "Nothing clearly matched", subtitle: "Closest results:")
    grid(find.closest)
    ForEach(find.notes, id: \.self) { note in
      Text(note).font(Roll.Typeface.caption).foregroundStyle(.rollInk3).fixedSize(horizontal: false, vertical: true)
    }
    next
  }

  @ViewBuilder private func found(_ result: PhotoSearch.Result) -> some View {
    AnswerTitle(title: AskModel.title(answer), subtitle: AskModel.subtitle(answer))
    RollSticker(text: "Matched by what’s in the photo")
    if let find = answer.find {
      FindResultBody(answer: answer, find: find, model: model, open: open, makeAlbum: makeAlbum, makeVideo: makeVideo)
    } else {
      grid(result.matches.map(\.id))
    }
    StreamedText(text: AskModel.reply(answer))
    next
  }

  @ViewBuilder private func grid(_ ids: [String]) -> some View {
    if model.picking == answer.id {
      ResultGrid(ids: ids, open: model.togglePick, isPicked: model.pick.contains)
    } else {
      ResultGrid(ids: ids, open: open)
    }
  }

  /// The actions and chips, on the actionable answer only.
  @ViewBuilder private var next: some View {
    if isActionable {
      if model.picking == answer.id {
        SeedPickBar(model: model).transition(.opacity)
      } else {
        // Side by side when they fit whole, stacked otherwise (a long count, "In Swipefiles", large text).
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Roll.Space.xs) { actions }
          VStack(alignment: .leading, spacing: Roll.Space.xs) { actions }
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
        RefineChips(answer: answer, model: model)
      }
    }
  }

  @ViewBuilder private var actions: some View {
    Button("Make album") {
      if let id = model.albumDraft(for: answer) { makeAlbum(id) }
    }
    .buttonStyle(.rollPrimary)
    .accessibilityIdentifier("ask.makeAlbum")
    Button { swipe(answer) } label: {
      HStack(spacing: 6) {
        Text(answer.toSwipe == 0 ? "Review the pile" : "Swipe through \(answer.toSwipe.formatted())")
        Image(systemName: "arrow.right").font(.footnote.weight(.bold)).opacity(0.6)
      }
    }
    .buttonStyle(.rollSecondary)
    if model.savedQueries.contains(answer.query) {
      Label("In Swipefiles", systemImage: "checkmark")
        .font(Roll.Typeface.label)
        .foregroundStyle(.rollInk2)
        .padding(.horizontal, Roll.Space.s)
    } else {
      Button(saving ? "Saving…" : "Save pile") {
        saving = true
        Task {
          await model.save(answer)
          saving = false
        }
      }
      .buttonStyle(.rollText)
      .disabled(saving)
    }
  }
}

/// "More like these" (or "Like 2 photos" once searched), "Older than a year", "Biggest first", "Only on this
/// iPhone": each toggles a new turn.
struct RefineChips: View {
  let answer: AskModel.Answer
  let model: AskModel

  var body: some View {
    let refinement = answer.refinement
    // Wraps onto a second line rather than hiding a chip off the edge.
    RollWrap {
      if answer.seeds.isEmpty {
        RollChip(title: "More like these", isOn: false) {
          withAnimation(Roll.Motion.ease) { model.startPicking(answer.id) }
        }
      } else {
        RollChip(title: SeedPick.chipTitle(answer.seeds.count), isOn: true) { model.reask(seeds: []) }
      }
      RollChip(title: "Older than a year", isOn: refinement.olderThanAYear) {
        model.refine { $0.olderThanAYear.toggle() }
      }
      RollChip(title: "Biggest first", isOn: refinement.biggestFirst) {
        model.refine { $0.biggestFirst.toggle() }
      }
      RollChip(title: "Only on this iPhone", isOn: refinement.onlyOnThisIPhone) {
        model.refine { $0.onlyOnThisIPhone.toggle() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The check in a picked cell's corner (blue: the album color), or an empty ring.
struct PickMark: View {
  let on: Bool

  var body: some View {
    ZStack {
      Circle().fill(on ? Roll.Palette.album : .black.opacity(0.18))
      Circle().strokeBorder(.white, lineWidth: 1.5)
      if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
    }
    .frame(width: 24, height: 24)
    .accessibilityHidden(true)
  }
}
