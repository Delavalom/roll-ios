import Commit
import Library
import Ranking
import Store
import SwiftUI

/// The card stack (spec §5), a step of the same conversation as Ask: the pile's title and a sticker that says how
/// it's learning, the deck, what's queued, and an action bar where the composer was. Left = the pile's action,
/// right = keep, up = add to an album, tap = full screen.
struct SwipeReviewView: View {
  /// How far a card must travel to count as a swipe.
  static let commitDistance: CGFloat = 120

  let swipefile: SwipefileRecord
  /// Under the title ("older than a year · 22 photos"); the pile's own line when nil.
  var subtitle: String?
  /// A fixed deck (a search answer) instead of the swipefile's own.
  var deck: (any SwipeDeck)?
  /// When each card's photo was taken, if known.
  var taken: [String: Double] = [:]
  /// After Review & apply closes, with what was applied.
  var onApplied: ((CommitReport?) -> Void)?
  @Environment(AppModel.self) private var app

  var body: some View {
    SwipeStack(model: SwipeReviewModel(app: app, swipefile: swipefile, deck: deck), subtitle: subtitle, taken: taken,
               onApplied: onApplied)
  }
}

private struct SwipeStack: View {
  @State var model: SwipeReviewModel
  let subtitle: String?
  let taken: [String: Double]
  let onApplied: ((CommitReport?) -> Void)?
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: CGSize = .zero
  @State private var committing = false
  @State private var fullScreen: String?
  @State private var dealt = false
  /// The Private pile on an iPhone with no passcode opened without a check: say how to lock it.
  @State private var showsNoPasscodeNote = false
  /// The first time any pile opens: what the swipes do (`SwipeHint`).
  @State private var showsHint = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      switch model.state {
      case .loading:
        RollEmptyState(title: "Dealing the cards", message: "Looking for the best matches first.", busy: true)
          .frame(maxHeight: .infinity)
      case .needsModel:
        RollEmptyState(title: "On-device AI not ready",
                       message: "This pile is found by describing it, which needs the on-device AI.") {
          Button("Retry") { app.loadModel() }.buttonStyle(.rollSecondary)
        }
        .frame(maxHeight: .infinity)
      case .failed:
        RollEmptyState(title: "This pile couldn't load", message: "Go back and open it again.")
          .frame(maxHeight: .infinity)
      case .ready:
        stack
      }
      queuedLine
    }
    .padding(.horizontal, Roll.Space.page)
    .safeAreaInset(edge: .bottom) { actionBar }
    .rollPage()
    .navigationTitle(model.swipefile.name)
    .toolbar(.visible, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) { Text("") }
      ToolbarItem(placement: .topBarLeading) {
        Button("Back", systemImage: "chevron.left") { dismiss() }.buttonStyle(.rollCircle)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Undo", systemImage: "arrow.uturn.backward") { Task { await model.undo() } }
          .buttonStyle(.rollCircle)
          .disabled(!model.canUndo)
      }
    }
    .navigationBarBackButtonHidden(true)
    .toolbar(.hidden, for: .tabBar)
    // Full screen hides the stack too: its images stop, and load again on the way back.
    .onAppear { model.appeared() }
    .onDisappear { model.disappeared() }
    .task { await model.watchWiFi() }
    .task {
      showsNoPasscodeNote = SwipefileListModel.isLocked(model.swipefile) && !SwipefileListModel.canLock
      showsHint = SwipeHint.isNeeded(app.environment.defaults)
      await model.load()
    }
    .onChange(of: app.modelState) { _, state in
      if state == .ready, model.state == .needsModel { Task { await model.load() } }
    }
    .onChange(of: model.state) { _, state in
      guard state == .ready, !dealt else { return }
      if reduceMotion { dealt = true } else { withAnimation(Roll.Motion.spring) { dealt = true } }
    }
    .sheet(isPresented: $committing, onDismiss: { Task { await model.committed() } }) {
      CommitSheet(app: app, swipefileIds: [model.swipefile.id], onClose: onApplied)
    }
    .fullScreenCover(item: Binding(get: { fullScreen.map(PhotoID.init) }, set: { fullScreen = $0?.id })) {
      FullScreenPhoto(id: $0.id)
    }
    .alert("Something went wrong", isPresented: Binding(get: { model.message != nil },
                                                        set: { if !$0 { model.message = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.message ?? "")
    }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.swipefile.name).rollTitle().lineLimit(2).accessibilityAddTraits(.isHeader)
        Text(subtitle ?? pileLine).font(Roll.Typeface.subhead).foregroundStyle(.rollInk2)
      }
      RollSticker(text: learning)
        .animation(Roll.Motion.quick, value: learning)
      if showsNoPasscodeNote {
        Label(SwipefileListModel.noPasscodeNote, systemImage: "lock.open")
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk2)
      }
      if showsHint, model.state == .ready, !model.cards.isEmpty {
        SwipeHint(action: model.swipefile.action, learns: model.learns, close: hintSeen)
          .padding(.top, Roll.Space.xxs)
          .transition(.opacity)
      }
    }
    .padding(.top, Roll.Space.xs)
    .padding(.bottom, Roll.Space.m)
  }

  private var pileLine: String {
    switch model.swipefile.action {
    case .delete: "Left deletes · right keeps · up adds to an album"
    case .album: "Left adds to the album · right keeps"
    case .squish: "Left squishes · right keeps"
    }
  }

  /// What this session's swipes add up to. Only what happened: counts, never an invented score.
  private var learning: String {
    if model.justUndid { return "Undone · that swipe is off the pile" }
    if model.looksDone { return "Looks done · finish when you’re ready" }
    let (hits, of) = model.onTarget()
    switch of {
    case 0: return model.learns ? "Learns from your swipes" : "Nothing changes until you apply"
    case 1, 2: return "\(of) \(of == 1 ? "swipe" : "swipes") so far"
    default: return "\(hits) of the last \(of) on target"
    }
  }

  // MARK: Deck

  @ViewBuilder private var stack: some View {
    if model.cards.isEmpty {
      VStack(spacing: Roll.Space.m) {
        DoneRing(size: 56)
        Text(model.queued.count > 0 ? "That's the pile" : "All caught up").rollTitle()
        Text(model.queued.count > 0 ? "Review what's queued before anything changes." : "Nothing left in this pile for now.")
          .font(Roll.Typeface.callout)
          .foregroundStyle(.rollInk2)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ZStack {
        ForEach(Array(model.cards.prefix(3).enumerated().reversed()), id: \.element.id) { index, card in
          if index == 0 {
            CardView(card: card, image: model.image(for: card), offset: drag, actionTitle: model.actionTitle,
                     taken: taken[card.id])
              .offset(drag)
              .rotationEffect(.degrees(Double(drag.width / 22)), anchor: .bottom)
              .gesture(dragGesture)
              .onTapGesture { fullScreen = card.id }
              .modifier(TopCardActions(gate: model.topGate, actionTitle: model.actionTitle, swipe: { swipe($0) },
                                       skip: { skip() }))
              .accessibilityIdentifier("swipe.topCard")
              .zIndex(3)
          } else {
            CardView(card: card, image: model.image(for: card), taken: taken[card.id])
              .scaleEffect(1 - CGFloat(index) * 0.045)
              .offset(y: CGFloat(index) * 10)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .opacity(dealt ? 1 : 0)
      .offset(y: dealt ? 0 : 60)
      .scaleEffect(dealt ? 1 : 0.92)
    }
  }

  // MARK: Queue and actions

  private var queuedLine: some View {
    HStack(alignment: .center, spacing: Roll.Space.s) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.queuedText)
          .font(Roll.Typeface.figure)
          .foregroundStyle(.rollInk)
          .contentTransition(.numericText())
          .animation(Roll.Motion.quick, value: model.queuedText)
          .accessibilityIdentifier("swipe.queued")
        Text("Nothing is deleted until you apply")
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk3)
      }
      Spacer(minLength: 0)
      if !model.cards.isEmpty {
        Button("Review & apply") { review() }
          .buttonStyle(.rollSecondary)
          .controlSize(.small)
          .disabled(model.queued.count == 0)
      }
    }
    .padding(.vertical, Roll.Space.s)
  }

  /// Where the composer sits in Ask: the three verdicts while the photo is on screen (only Skip without it: no delete,
  /// keep or album for a photo the user can't see); once the deck is empty, Review & apply.
  @ViewBuilder private var actionBar: some View {
    let gate = model.topGate
    Group {
      if model.cards.isEmpty, model.state == .ready {
        Button { review() } label: {
          Text("Review & apply · \(model.queued.count.formatted()) \(model.queued.count == 1 ? "item" : "items")")
        }
        .buttonStyle(.roll(.primary, fullWidth: true))
        .disabled(model.queued.count == 0)
        .accessibilityLabel("Review & apply")
        .accessibilityValue("\(model.queued.count.formatted()) queued")
      } else {
        HStack(spacing: 6) {
          if gate == .skipOnly {
            segment("Skip", dot: .rollInk3, kind: .secondary) { skip() }
          } else {
            segment("Keep", dot: .rollKeep, kind: .secondary) { swipe(.keep) }.disabled(gate != .decide)
          }
          segment("Album", dot: .rollAlbum, kind: .secondary) { swipe(.album) }.disabled(gate != .decide)
          segment(model.actionTitle, dot: nil, kind: .primary) { swipe(.action) }.disabled(gate != .decide)
        }
        .disabled(model.cards.isEmpty || model.state != .ready)
      }
    }
    .padding(6)
    .background(.rollCard, in: Capsule())
    .overlay { Capsule().strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth) }
    .rollShadow()
    .padding(.horizontal, Roll.Space.m)
    .padding(.bottom, Roll.Space.xs)
    .animation(Roll.Motion.ease, value: model.cards.isEmpty)
  }

  private func segment(_ title: String, dot: Color?, kind: RollButtonStyle.Kind,
                       action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let dot { Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true) }
        Text(title)
      }
    }
    .buttonStyle(RollButtonStyle(kind: kind, fullWidth: true))
    .accessibilityLabel(title)
  }

  private func review() {
    Task {
      await model.flush()
      committing = true
    }
  }

  // MARK: Gestures

  private var dragGesture: some Gesture {
    DragGesture()
      .onChanged { drag = $0.translation }
      .onEnded { value in
        let t = value.translation, d = SwipeReviewView.commitDistance
        let verdict: Verdict? = if -t.height > d, -t.height > abs(t.width) { .album }
          else if t.width < -d { .action }
          else if t.width > d { .keep }
          else { nil }
        guard let verdict, model.topGate != .wait else {
          withAnimation(Roll.Motion.spring) { drag = .zero }
          return
        }
        if model.topGate == .skipOnly { skip(from: t) } else { swipe(verdict, from: t) }
      }
  }

  /// Closed, or the first card was swiped: never shown again.
  private func hintSeen() {
    guard showsHint else { return }
    SwipeHint.markSeen(app.environment.defaults)
    withAnimation(Roll.Motion.quick) { showsHint = false }
  }

  private func swipe(_ verdict: Verdict, from translation: CGSize? = nil) {
    hintSeen()
    let exit: CGSize = switch verdict {
    case .action: CGSize(width: -560, height: translation?.height ?? 40)
    case .keep: CGSize(width: 560, height: translation?.height ?? 40)
    case .album: CGSize(width: translation?.width ?? 0, height: -900)
    }
    // From a button, the card leans first so the tag shows, then leaves.
    if translation == nil, !reduceMotion {
      let lean = CGSize(width: exit.width.sign == .minus ? -70 : exit.width == 0 ? 0 : 70,
                        height: verdict == .album ? -70 : 0)
      withAnimation(Roll.Motion.quick) { drag = lean } completion: { leave(to: exit) { model.swipe(verdict) } }
    } else {
      leave(to: exit) { model.swipe(verdict) }
    }
  }

  private func leave(to exit: CGSize, then done: @escaping () -> Void) {
    withAnimation(Roll.Motion.exit) { drag = exit } completion: {
      done()
      drag = .zero
    }
  }

  /// A card with nothing on screen leaves the way it was pushed (to the left from the Skip button), with no decision.
  private func skip(from translation: CGSize? = nil) {
    let t = translation ?? CGSize(width: -1, height: 0)
    let exit = -t.height > abs(t.width) ? CGSize(width: t.width, height: -900)
      : CGSize(width: t.width < 0 ? -560 : 560, height: t.height)
    leave(to: exit) { model.skip() }
  }
}

/// VoiceOver actions on the top card, by what its photo allows.
private struct TopCardActions: ViewModifier {
  let gate: CardGate
  let actionTitle: String
  let swipe: (Verdict) -> Void
  let skip: () -> Void

  func body(content: Content) -> some View {
    switch gate {
    case .decide:
      content
        .accessibilityAction(named: actionTitle) { swipe(.action) }
        .accessibilityAction(named: "Keep") { swipe(.keep) }
        .accessibilityAction(named: "Add to album") { swipe(.album) }
    case .skipOnly:
      content.accessibilityAction(named: "Skip") { skip() }
    case .wait:
      content
    }
  }
}

private struct PhotoID: Identifiable {
  let id: String
}

#if DEBUG
#Preview("Screenshots") {
  PreviewHost {
    NavigationStack { SwipeReviewView(swipefile: Preset.screenshots.swipefile(created: 0)) }
  }
}

#Preview("Memes, AI not ready") {
  PreviewHost(modelReady: false) {
    NavigationStack { SwipeReviewView(swipefile: Preset.memes.swipefile(created: 0)) }
  }
}
#endif
