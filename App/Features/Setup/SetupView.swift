import Setup
import SwiftUI
import UIKit

/// "Set up on-device AI": what it unlocks, one tap, then the two stages with their progress. The last onboarding step
/// (with Photos access) and, from Home's setup card, a sheet. While it shows and setup runs, the screen stays awake
/// (people leave it on the table); on iOS 26 setup also keeps going when Roll leaves the screen (`ContinuedSetup`).
struct SetupView: View {
  enum Context {
    /// Continue finishes onboarding; "Not now" skips the tap.
    case onboarding
    /// From Home: Done dismisses.
    case sheet
  }

  @Environment(AppModel.self) private var app
  let context: Context
  let onContinue: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        RollMark(size: 72, busy: running)
          .padding(.top, context == .onboarding ? 56 : Roll.Space.xxl)
        Text(app.setup.isDone ? "Roll is ready" : "Set up on-device AI")
          .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .padding(.top, Roll.Space.xl)
        Text(app.setup.isDone
             ? "Describe a photo and Roll finds it."
             : "Describe a photo and Roll finds it: a trip, a place, a day. It makes albums from what you find, too.")
          .font(Roll.Typeface.body)
          .foregroundStyle(.rollInk2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Roll.Space.s)
        RollSticker(text: "Runs on this iPhone. Nothing leaves it.")
          .padding(.top, Roll.Space.m)

        if app.setup.started {
          progress.padding(.top, Roll.Space.xl)
        } else {
          Text("Takes a while the first time: usually 20–40 minutes. Best on Wi-Fi and plugged in.")
            .font(Roll.Typeface.subhead)
            .foregroundStyle(.rollInk2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Roll.Space.xl)
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom) { actions }
    .rollPage()
    .onAppear(perform: updateIdleTimer)
    .onChange(of: running) { updateIdleTimer() }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }

  /// Started and not done: the screen stays on while this shows.
  private var running: Bool { app.setup.started && !app.setup.isDone }

  private func updateIdleTimer() {
    UIApplication.shared.isIdleTimerDisabled = running
  }

  // MARK: Progress

  @ViewBuilder private var progress: some View {
    VStack(alignment: .leading, spacing: Roll.Space.m) {
      SetupStageRow(title: SetupText.modelStage, detail: modelDetail, value: modelValue, done: app.engine != nil,
                    active: modelActive)
      SetupStageRow(title: SetupText.libraryStage, detail: libraryDetail, value: libraryValue,
                    done: app.setup.isDone, active: app.engine != nil && !app.setup.isDone)
    }
    .rollCard()

    if modelBlocked {
      ModelStatusView().padding(.top, Roll.Space.s)
    }

    if !app.setup.isDone {
      Text(app.setup.continuesInBackground
           ? "Usually 20–40 minutes. Best on Wi-Fi and plugged in. You can leave Roll; it keeps going and can tell you when it's done."
           : "Usually 20–40 minutes. Best on Wi-Fi and plugged in. Keep Roll open, or leave your iPhone charging overnight.")
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Roll.Space.m)
      notifyButton.padding(.top, Roll.Space.s)
    }
  }

  private var notifyButton: some View {
    Button {
      Task { await app.setup.setNotifyWhenReady(!app.setup.notifyWhenReady) }
    } label: {
      Label(app.setup.notifyWhenReady ? "We'll tell you when it's ready" : "Tell me when it's ready",
            systemImage: app.setup.notifyWhenReady ? "bell.fill" : "bell")
    }
    .buttonStyle(.rollSecondary)
    .accessibilityIdentifier("setup.notify")
    .accessibilityAddTraits(app.setup.notifyWhenReady ? .isSelected : [])
  }

  /// The model is waiting for a network or stopped (space, failure): ModelStatusView has the choices.
  private var modelBlocked: Bool {
    guard app.engine == nil else { return false }
    switch app.modelState {
    case .waiting: return true
    case .unavailable(let issue): return issue != .notStarted
    default: return false
    }
  }

  private var modelActive: Bool { app.engine == nil && !modelBlocked }

  private var modelDetail: String {
    if app.engine != nil { return "Ready" }
    if case .model(let step) = app.setup.progress.stage { return SetupText.modelDetail(step) }
    if let step = app.setupModelStep { return SetupText.modelDetail(step) }
    return modelBlocked ? "Stopped" : "Starting"
  }

  private var modelValue: Double {
    if app.engine != nil { return 1 }
    guard case .model = app.setup.progress.stage else { return 0 }
    return min(1, app.setup.progress.overall / SetupProgress.modelEnd)
  }

  private var libraryDetail: String {
    if let counts = app.setup.counts { return SetupText.libraryDetail(counts) }
    return "Starts once the AI is ready"
  }

  private var libraryValue: Double {
    guard let counts = app.setup.counts, counts.total > 0 else { return app.setup.isDone ? 1 : 0 }
    return Double(counts.read) / Double(counts.total)
  }

  // MARK: Actions

  private var actions: some View {
    VStack(spacing: Roll.Space.xxs) {
      if app.setup.started {
        Button(context == .sheet ? "Done" : "Continue", action: onContinue)
          .buttonStyle(.roll(.primary, fullWidth: true))
          .accessibilityIdentifier("setup.continue")
      } else {
        Button("Set up") { app.beginSetup() }
          .buttonStyle(.roll(.primary, fullWidth: true))
          .accessibilityIdentifier("setup.start")
        if context == .onboarding {
          Button("Not now", action: onContinue)
            .buttonStyle(.rollText)
            .accessibilityIdentifier("setup.notNow")
        }
      }
    }
    .padding(.horizontal, Roll.Space.page)
    .padding(.top, Roll.Space.s)
    .padding(.bottom, Roll.Space.xs)
    .background(Roll.Palette.paper.ignoresSafeArea(edges: .bottom))
  }
}

/// One stage: a checkmark once done, a busy mark while it runs, the detail line and its bar.
private struct SetupStageRow: View {
  let title: String
  let detail: String
  let value: Double
  let done: Bool
  let active: Bool

  var body: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      Group {
        if done {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.rollKeep)
        } else {
          RollMark(size: 24, busy: active).opacity(active ? 1 : 0.35)
        }
      }
      .frame(width: 28, height: 28)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(Roll.Typeface.headline).foregroundStyle(done || active ? .rollInk : .rollInk3)
        Text(detail)
          .font(Roll.Typeface.figure)
          .foregroundStyle(.rollInk2)
          .contentTransition(.numericText())
          .fixedSize(horizontal: false, vertical: true)
        if !done { RollProgressBar(value: value).padding(.top, 6) }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(done ? Text("Done") : Text(detail))
  }
}
