import Ranking
import SwiftUI

// The pieces of an Ask conversation: the composer, the user's bubble, Roll's turn, an answer, the results grid.

/// The composer at the foot of Home: a white capsule with the mark as its send button. Above it, while typing, how
/// many photos match so far (searched as you type, on this iPhone).
struct AskComposer: View {
  @Bindable var model: AskModel
  var focused: FocusState<Bool>.Binding

  var body: some View {
    VStack(spacing: Roll.Space.xs) {
      if let live = model.live, !model.draft.isEmpty {
        LiveStrip(count: live.count, ids: live.ids)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      HStack(spacing: Roll.Space.xs) {
        TextField(placeholder, text: $model.draft, axis: .horizontal)
          .font(Roll.Typeface.body)
          .foregroundStyle(.rollInk)
          .tint(.rollEmber)
          .submitLabel(.search)
          .focused(focused)
          .onSubmit { model.submit() }
          .disabled(!model.canAsk)
          .padding(.leading, Roll.Space.l)
          .accessibilityIdentifier("ask.composer")
        Button {
          model.submit()
        } label: {
          RollMark(size: 40, busy: model.searching)
        }
        .buttonStyle(PressScale())
        .disabled(!model.canAsk || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        .opacity(model.canAsk ? 1 : 0.4)
        .accessibilityLabel("Search")
      }
      .padding(.trailing, 8)
      .frame(height: Roll.Size.composer)
      .background(.rollCard, in: Capsule())
      .overlay { Capsule().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
      .rollShadow(lifted: focused.wrappedValue)
    }
    .padding(.horizontal, Roll.Space.m)
    .padding(.bottom, Roll.Space.xs)
    .padding(.top, Roll.Space.l)
    .background {
      LinearGradient(colors: [Roll.Palette.paper.opacity(0), Roll.Palette.paper], startPoint: .top,
                     endPoint: UnitPoint(x: 0.5, y: 0.45))
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
    .animation(Roll.Motion.ease, value: model.live?.count)
    .animation(Roll.Motion.ease, value: model.draft.isEmpty)
  }

  private var placeholder: String {
    if !model.canAsk { return "On-device AI is getting ready…" }
    return model.isChatting ? "Ask for more…" : "Describe what to clear…"
  }
}

/// "12 match so far · on this iPhone", with the first few.
private struct LiveStrip: View {
  let count: Int
  let ids: [String]

  var body: some View {
    HStack(spacing: Roll.Space.xs) {
      HStack(spacing: -8) {
        ForEach(ids, id: \.self) { id in
          Thumbnail(id: id, side: 120)
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.rollCard, lineWidth: 2) }
        }
      }
      Text("\(Text(count.formatted()).foregroundStyle(.rollInk).fontWeight(.semibold)) \(count == 1 ? "match" : "matches") so far · on this iPhone")
        .font(Roll.Typeface.caption)
        .foregroundStyle(.rollInk2)
        .contentTransition(.numericText())
    }
    .padding(.leading, 6)
    .padding(.trailing, Roll.Space.s)
    .frame(height: 36)
    .background(.rollCard, in: Capsule())
    .overlay { Capsule().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// The user's words, right-aligned in ink.
struct UserBubble: View {
  let text: String

  var body: some View {
    HStack {
      Spacer(minLength: 56)
      Text(text)
        .font(Roll.Typeface.body)
        .foregroundStyle(.rollOnInk)
        .padding(.horizontal, Roll.Space.m)
        .padding(.vertical, 11)
        .background(.rollInk, in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                                          bottomTrailingRadius: 6, topTrailingRadius: 22,
                                                          style: .continuous))
    }
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}

/// Roll's side of the conversation: the mark (turning while it works) and the turn's content.
struct RollTurn<Content: View>: View {
  var busy = false
  var showsMark = true
  @ViewBuilder let content: Content

  var body: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      if showsMark { RollMark(size: Roll.Size.avatar, busy: busy) } else { Color.clear.frame(width: Roll.Size.avatar) }
      VStack(alignment: .leading, spacing: Roll.Space.s) { content }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .transition(.opacity.combined(with: .offset(y: 12)))
  }
}

/// A title with its line underneath ("Screenshots of chats" / "38 photos · about 214 MB").
struct AnswerTitle: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).rollTitle().fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
      if !subtitle.isEmpty { Text(subtitle).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2) }
    }
  }
}

/// One answer: what Roll did (counted and measured), what it found, why, the grid, a reply built from the dates,
/// and, on the actionable answer (the last one that came back), what to do next.
struct AnswerView: View {
  let answer: AskModel.Answer
  let isActionable: Bool
  let model: AskModel
  let swipe: (AskModel.Answer) -> Void
  let open: (String) -> Void

  @State private var saving = false

  var body: some View {
    RollTurn(busy: answer.result == nil && answer.failure == nil) {
      if let failure = answer.failure {
        AnswerTitle(title: "That search didn't run", subtitle: failure)
      } else if let result = answer.result {
        StatusLine(text: AskModel.elapsed(result), done: true)
        if result.matches.isEmpty {
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
      nothingStoodOut(result)
    }
  }

  @ViewBuilder private func nothingStoodOut(_ result: PhotoSearch.Result) -> some View {
    AnswerTitle(title: "Nothing stood out",
                subtitle: answer.isRefinement ? "None of the matches fit that. Change the filters below."
                  : "Try what's in the photo, like “receipts” or “screenshots of maps”.")
    if !result.weaker.isEmpty {
      Text("\(result.weaker.count.formatted()) weaker \(result.weaker.count == 1 ? "match" : "matches") folded")
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk3)
    }
    // A refinement that empties the answer can always be undone from here.
    if isActionable, answer.isRefinement { RefineChips(refinement: answer.refinement, model: model) }
  }

  @ViewBuilder private func found(_ result: PhotoSearch.Result) -> some View {
    AnswerTitle(title: AskModel.title(answer), subtitle: AskModel.subtitle(answer))
    RollSticker(text: "Matched by what’s in the photo")
    let shown = answer.expanded ? result.matches : Array(result.matches.prefix(AskModel.previewCount))
    ResultGrid(ids: shown.map(\.id), open: open)
    if let more = AskModel.more(result, showing: shown.count) {
      Button(more) { withAnimation(Roll.Motion.ease) { model.expand(answer.id) } }
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .disabled(answer.expanded)
    }
    StreamedText(text: AskModel.reply(answer))
    if isActionable {
      // Side by side when both fit whole, stacked otherwise (a long count, "In Swipefiles", large text).
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Roll.Space.xs) { actions(answer) }
        VStack(alignment: .leading, spacing: Roll.Space.xs) { actions(answer) }
      }
      .transition(.opacity.combined(with: .offset(y: 8)))
      RefineChips(refinement: answer.refinement, model: model)
    }
  }

  @ViewBuilder private func actions(_ answer: AskModel.Answer) -> some View {
    Button { swipe(answer) } label: {
      HStack(spacing: 6) {
        Text(answer.toSwipe == 0 ? "Review the pile" : "Swipe through \(answer.toSwipe.formatted())")
        Image(systemName: "arrow.right").font(.footnote.weight(.bold)).opacity(0.6)
      }
    }
    .buttonStyle(.rollPrimary)
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
      .buttonStyle(.rollSecondary)
      .disabled(saving)
    }
  }
}

/// "Older than a year", "Biggest first", "Only on this iPhone": each toggles a new turn.
private struct RefineChips: View {
  let refinement: PhotoSearch.Refinement
  let model: AskModel

  var body: some View {
    // Wraps onto a second line rather than hiding a chip off the edge.
    RollWrap {
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

/// Three columns of square thumbnails that sharpen in one after another.
struct ResultGrid: View {
  let ids: [String]
  let open: (String) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 4) {
      ForEach(Array(ids.enumerated()), id: \.element) { index, id in
        RevealCell(id: id, delay: Double(min(index, 12)) * 0.035)
          .onTapGesture { open(id) }
          .accessibilityElement()
          .accessibilityLabel("Photo \(index + 1)")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { open(id) }
      }
    }
  }
}

private struct RevealCell: View {
  let id: String
  let delay: Double
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      // The longer side: a tall screenshot filling a square cell needs about this much to stay sharp at 3x.
      .overlay { Thumbnail(id: id, side: 800) }
      .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
      .blur(radius: shown ? 0 : 8)
      .opacity(shown ? 1 : 0)
      .scaleEffect(shown ? 1 : 0.96)
      .onAppear {
        guard !shown else { return }
        if reduceMotion { shown = true } else { withAnimation(Roll.Motion.ease.delay(delay)) { shown = true } }
      }
  }
}

/// Text that arrives a word at a time, the way the answer reads out (all at once with Reduce Motion).
struct StreamedText: View {
  let text: String
  @State private var shown = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let words = text.split(separator: " ", omittingEmptySubsequences: false)
    Text(words.prefix(shown).joined(separator: " "))
      .font(Roll.Typeface.body)
      .foregroundStyle(.rollInk)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Lays out at full height from the start, so nothing below jumps while it streams.
      .background(alignment: .topLeading) {
        Text(text).font(Roll.Typeface.body).fixedSize(horizontal: false, vertical: true).hidden()
      }
      .accessibilityLabel(text)
      .task(id: text) {
        if reduceMotion || shown >= words.count { shown = words.count; return }
        while shown < words.count {
          try? await Task.sleep(for: .milliseconds(34))
          if Task.isCancelled { return }
          shown += 1
        }
      }
  }
}

/// A cleanup suggestion on Home and after applying: fanned thumbnails, a title and its count and size.
struct SuggestionCard: View {
  let ids: [String]
  let symbol: String
  let title: String
  let detail: String
  var note: String?

  var body: some View {
    HStack(spacing: Roll.Space.s) {
      if ids.isEmpty {
        RollIconTile(symbol: symbol).frame(width: 46 * 1.9, height: 54)
      } else {
        ThumbFan(ids: ids)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
        Text(detail).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2)
        if let note { Text(note).font(Roll.Typeface.caption).foregroundStyle(.rollInk3) }
      }
      Spacer(minLength: Roll.Space.xs)
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.bold))
        .foregroundStyle(.rollInk3)
    }
    .rollCard(padding: Roll.Space.s)
    .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
