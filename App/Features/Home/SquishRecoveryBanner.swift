import SwiftUI
import UIKit

/// Shown on Home when a squish didn't finish (an interruption found by `ReplaceFlow.reconcile()`, or a squish prompt
/// that was declined or failed): replace the originals of verified copies or remove those copies, and remove copies
/// that were never verified. Unobtrusive: a notice card, not a modal.
struct SquishRecoveryBanner: View {
  @Environment(AppModel.self) private var app
  @State private var working = false
  @State private var showingPaywall = false

  var body: some View {
    let recovery = app.squishRecovery
    if !recovery.isEmpty || app.openSquishesNeedingFullAccess > 0 {
      HStack(alignment: .top, spacing: Roll.Space.s) {
        RollIconTile(symbol: "film.stack")
        VStack(alignment: .leading, spacing: Roll.Space.xs) {
          Text("A squish didn't finish")
            .font(Roll.Typeface.headline)
            .foregroundStyle(.rollInk)
            .accessibilityAddTraits(.isHeader)
          if app.openSquishesNeedingFullAccess > 0 {
            message("Give Roll Full Access to Photos to finish or remove the smaller copies it made.")
            Button("Open Settings") {
              if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.rollSecondary)
          }
          if !recovery.pending.isEmpty {
            message("\(recovery.pending.count) smaller \(recovery.pending.count == 1 ? "copy is" : "copies are") ready next to the originals.")
            ViewThatFits(in: .horizontal) {
              HStack(spacing: Roll.Space.xs) { pendingActions }
              VStack(alignment: .leading, spacing: Roll.Space.xs) { pendingActions }
            }
            if app.squishRecoveryBlockedByQuota > 0 {
              Button {
                showingPaywall = true
              } label: {
                Label("\(app.squishRecoveryBlockedByQuota) more \(app.squishRecoveryBlockedByQuota == 1 ? "needs" : "need") Roll Pro. The first 50 cleanups are free.",
                      systemImage: "lock.fill")
                  .font(Roll.Typeface.label)
                  .foregroundStyle(.rollInk)
                  .multilineTextAlignment(.leading)
                  .frame(minHeight: Roll.Size.control)
                  .contentShape(Rectangle())
              }
              .buttonStyle(PressScale())
            }
          }
          if !recovery.orphanCopyIDs.isEmpty {
            HStack(spacing: Roll.Space.xs) {
              message("\(recovery.orphanCopyIDs.count) unchecked \(recovery.orphanCopyIDs.count == 1 ? "copy" : "copies") left behind.")
              Spacer(minLength: 0)
              Button("Remove") { run { await app.discardSquishOrphans() } }
                .buttonStyle(.rollSecondary)
            }
          }
          if let message = app.squishMessage {
            Label(message, systemImage: "exclamationmark.circle")
              .font(Roll.Typeface.subhead)
              .foregroundStyle(.rollInk)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .rollCard()
      .disabled(working)
      .sheet(isPresented: $showingPaywall) {
        PaywallView(provider: app.entitlements, pitch: app.home.paywallPitch) { showingPaywall = false }
      }
    }
  }

  @ViewBuilder private var pendingActions: some View {
    Button("Replace originals") { run { await app.finishPendingSquishes() } }
      .buttonStyle(.rollSecondary)
    Button("Remove copies", role: .destructive) { run { await app.discardPendingSquishes() } }
      .buttonStyle(.rollSecondary)
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(Roll.Typeface.subhead)
      .foregroundStyle(.rollInk2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func run(_ work: @escaping @MainActor () async -> Void) {
    working = true
    Task {
      await work()
      working = false
    }
  }
}
