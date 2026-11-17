import Setup
import SwiftUI

/// Home's top notice. While setup isn't finished (`AppModel.showsSetupCard`): the stage, one bar over the whole setup,
/// the free cleanup to do meanwhile, and the one tap ("Set up", or "Finish setting up" after an update, a purge or a
/// stop), which opens `SetupView`. A model that waits for Wi-Fi or stopped shows `ModelStatusView` below it, with its
/// choices. Otherwise just `ModelStatusView` (the low-storage note once ready).
struct SetupCard: View {
  @Environment(AppModel.self) private var app
  @State private var showingSetup = false

  var body: some View {
    Group {
      if app.showsSetupCard {
        VStack(spacing: Roll.Space.s) {
          card
          if modelBlocked { ModelStatusView() }
        }
      } else {
        ModelStatusView()
      }
    }
    // Outside the card: the sheet stays up when setup finishes and the card goes away.
    .sheet(isPresented: $showingSetup) {
      SetupView(context: .sheet) { showingSetup = false }
        .environment(app)
    }
  }

  private var card: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      RollMark(size: 36, busy: !modelBlocked)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
        Text(detail)
          .font(Roll.Typeface.figure)
          .foregroundStyle(.rollInk2)
          .contentTransition(.numericText())
          .fixedSize(horizontal: false, vertical: true)
        RollProgressBar(value: app.setup.stageFraction).padding(.vertical, 6)
        Text(invitation)
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
          .fixedSize(horizontal: false, vertical: true)
        if let action = actionTitle {
          Button(action) {
            app.beginSetup()
            showingSetup = true
          }
          .buttonStyle(.rollSecondary)
          .accessibilityIdentifier("setup.card.action")
          .padding(.top, Roll.Space.xs)
        }
      }
      Spacer(minLength: 0)
    }
    .rollCard()
    .accessibilityElement(children: .contain)
  }

  private var title: String {
    if app.setup.finishedOnce, app.engine == nil { return "Roll was updated: finish setting up the AI" }
    switch app.setup.progress.stage {
    case .library: return SetupText.libraryStage
    default: return app.setup.started ? SetupText.modelStage : "Set up on-device AI"
    }
  }

  private var detail: String {
    switch app.setup.progress.stage {
    case .model(let step): return SetupText.modelDetail(step)
    case .library(let counts): return SetupText.libraryDetail(counts)
    default:
      if let step = app.setupModelStep { return SetupText.modelDetail(step) }
      return "Describe a photo to find it, once it's set up"
    }
  }

  /// Cleanup needs no AI: offered while the wait goes on.
  private var invitation: String {
    let screenshots = app.home.summary[.screenshots].count
    return screenshots > 0
      ? "Cleanup works now: clear \(screenshots.formatted()) \(screenshots == 1 ? "screenshot" : "screenshots") while you wait."
      : "Cleanup works now: start with the piles below while you wait."
  }

  /// "Set up" before the first tap; "Finish setting up" when it isn't running in the background for the person.
  private var actionTitle: String? {
    if !app.setup.started { return "Set up" }
    return app.setup.continuing ? nil : "Finish setting up"
  }

  private var modelBlocked: Bool {
    guard app.engine == nil else { return false }
    switch app.modelState {
    case .waiting: return true
    case .unavailable(let issue): return issue != .notStarted
    default: return false
    }
  }
}
