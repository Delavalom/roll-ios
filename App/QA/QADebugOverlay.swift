import SwiftUI

extension View {
  /// DEBUG device QA (`-QAMetrics`, `-QAAlbum`): starts the recorder and shows the QA scope badge. A no-op without
  /// those launch arguments, and in Release builds (which compile nothing else from App/QA).
  func qaDebugOverlay() -> some View {
    #if DEBUG
    modifier(QADebugOverlay())
    #else
    self
    #endif
  }
}

#if DEBUG
import Commit
import Entitlements
import UIKit

private struct QADebugOverlay: ViewModifier {
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    if let runtime = QARuntime.shared {
      content
        .overlay(alignment: .top) { QABadge(runtime: runtime) }
        .onAppear { QAKeepAwake.apply() }
        // iOS resets nothing here, but setting it on every activation keeps a long device run from locking the phone
        // (its Auto-Lock has no "Never"), including after XCUITest relaunches the app.
        .onChange(of: scenePhase) { _, phase in if phase == .active { QAKeepAwake.apply() } }
        .task { QAController.start(runtime: runtime, app: app) }
    } else {
      content
    }
  }
}

/// DEBUG device QA only: the screen stays on while Roll runs in QA mode (any -QA* argument).
enum QAKeepAwake {
  @MainActor static func apply() {
    UIApplication.shared.isIdleTimerDisabled = true
    QARuntime.shared?.log.write("keep_awake", ["idleTimerDisabled": .bool(UIApplication.shared.isIdleTimerDisabled)])
  }
}

/// Starts the metrics recorder once, keeps the screen awake, and in QA-album mode re-inventories the album whenever
/// its item count changes.
@Observable @MainActor
final class QAController {
  static let shared = QAController()

  private(set) var albumCount: Int?
  private(set) var albumState = "checking"
  /// `-QARestock`: "waiting for full access", "running", then `QARestock.Summary.label`. Nil without the flag.
  private(set) var restockState: String?
  @ObservationIgnored private var metrics: QAMetrics?
  @ObservationIgnored private var sequence = 0
  @ObservationIgnored private var started = false

  static func start(runtime: QARuntime, app: AppModel) {
    guard !shared.started else { return }
    shared.started = true
    shared.run(runtime: runtime, app: app)
  }

  private func run(runtime: QARuntime, app: AppModel) {
    QAKeepAwake.apply()  // the phone must not lock during a long QA run
    let metrics = QAMetrics(runtime: runtime, app: app)
    metrics.start()
    self.metrics = metrics
    let arguments = ProcessInfo.processInfo.arguments
    Task {
      if arguments.contains("-QAExhaustFreeQuota") {
        let spent = (try? await app.quota.consumeUpTo(FreeQuota.limit)) ?? 0
        runtime.log.write("qa_exhaust_quota", ["spent": .int(spent), "remaining": .int((try? await app.quota.remaining()) ?? -1)])
      }
    }
    if arguments.contains("-QASearchBench") { QASearchBench.start(app: app, log: runtime.log) }
    if arguments.contains("-QAThumbProbe") {
      Task {
        try? await Task.sleep(for: .seconds(90))  // let the launch sync settle first
        runtime.log.write("thumb_probe_start", [:])
        await QAThumbProbe.run(sample: 200, log: runtime.log)
        runtime.log.write("thumb_probe_done", [:])
      }
    }
    guard let title = runtime.albumTitle else { return }
    Task {
      if runtime.restocks {
        restockState = "QA restock: waiting for full Photos access"
        while app.access != .full, !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
        restockState = "QA restock: running"
        restockState = await QARestock.run(title: title, runtime: runtime, repositories: app.repositories).label
      }
      var experimentDone = !runtime.runsDolbyVisionExperiment
      while !Task.isCancelled {
        let lookup = PhotoKitQAAlbum.lookup(title: title)
        let count: Int? = if case .found(let ids) = lookup { ids.count } else { nil }
        switch lookup {
        case .missing: albumState = "missing"
        case .ambiguous(let n): albumState = "ambiguous (\(n) albums)"
        case .found(let ids): albumState = "\(ids.count) items"
        }
        if count != albumCount || sequence == 0 {
          albumCount = count
          sequence += 1
          if app.access == .full {
            _ = await QAInventoryRunner.run(title: title, sequence: sequence, log: runtime.log)
          } else {
            sequence -= 1  // try again once access is granted
          }
        }
        if !experimentDone, count != nil, app.access == .full {
          experimentDone = true
          await QAInventoryRunner.dolbyVisionExperiment(title: title, log: runtime.log)
        }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }
}

private struct QABadge: View {
  let runtime: QARuntime
  @State private var pause = QAPause.shared
  @State private var controller = QAController.shared

  var body: some View {
    VStack(spacing: 6) {
      if runtime.albumTitleMissing {
        Text("QA · -QAAlbum has no title · read-only, nothing can change")
          .font(.caption2.monospaced())
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(.red.opacity(0.85), in: Capsule())
          .foregroundStyle(.white)
          .accessibilityIdentifier("qa.scope")
          .accessibilityLabel("QA scope missing: read-only")
          .allowsHitTesting(false)
      }
      if let title = runtime.albumTitle {
        let state = controller.albumState
        Text("QA · \(title) · \(state)")
          .font(.caption2.monospaced())
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(.yellow.opacity(0.85), in: Capsule())
          .foregroundStyle(.black)
          .accessibilityIdentifier("qa.scope")
          .accessibilityLabel("QA scope \(title): \(state)")
          .allowsHitTesting(false)
      }
      if let restock = controller.restockState {
        Text(restock)
          .font(.caption2.monospaced())
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(.yellow.opacity(0.85), in: Capsule())
          .foregroundStyle(.black)
          .accessibilityIdentifier("qa.restock")
          .accessibilityLabel(restock)
          .allowsHitTesting(false)
      }
      if let originals = pause.waitingOriginals {
        VStack(spacing: 6) {
          Text("QA paused before deleting \(originals) squished \(originals == 1 ? "original" : "originals"). Change an original in Photos now, then come back.")
            .font(.caption)
            .multilineTextAlignment(.center)
          Button("QA: continue to delete") { pause.resume() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("qa.continueDelete")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
      }
    }
  }
}
#endif
