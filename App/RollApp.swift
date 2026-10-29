import Indexer
import ModelInstall
import SwiftUI
import UIKit

@main
struct RollApp: App {
  @UIApplicationDelegateAdaptor(RollAppDelegate.self) private var delegate
  @State private var app: AppModel?
  private let failure: String?

  init() {
    RollAppearance.apply()
    do {
      let model = try AppModel.live()
      // BackgroundTasks needs the handler registered before launch finishes.
      IndexScheduler.register(indexer: { [indexer = model.indexer] in indexer },
                              text: { [text = model.textIndexer] in text })
      model.start()
      _app = State(initialValue: model)
      failure = nil
    } catch {
      IndexScheduler.register { nil }
      failure = String(describing: error)
    }
  }

  var body: some Scene {
    WindowGroup {
      if let app {
        RootView().environment(app)
      } else {
        LaunchFailureView(detail: failure ?? "")
      }
    }
  }
}

/// Hands the model download's background-session events to `BackgroundTransport` (iOS relaunches Roll in the
/// background when the download finishes while Roll isn't running).
final class RollAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                   completionHandler: @escaping () -> Void) {
    nonisolated(unsafe) let done = completionHandler  // called once, on the main queue
    if !BackgroundTransport.shared.handleEvents(forSession: identifier, completion: { done() }) { completionHandler() }
  }
}

/// The database couldn't open. Nothing else can work without it.
private struct LaunchFailureView: View {
  let detail: String

  var body: some View {
    RollEmptyState(title: "Roll couldn't start",
                   message: "Its database couldn't be opened. Restart the app; if this keeps happening, reinstall Roll.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .rollPage()
      .accessibilityElement(children: .combine)
      .accessibilityHint(detail)
  }
}
