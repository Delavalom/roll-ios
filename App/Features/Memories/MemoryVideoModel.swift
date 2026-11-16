import Foundation
import Memories
import Observation
import Overview

/// "Make a video": picks the shots (`MemoryReelPlanner` over what the Store knows, `MemoryReelInput`), renders them on
/// the iPhone (`MemoryVideoExporter`) with progress and cancel, then offers a preview, Share and Save to Photos. The
/// rendered file lives in a temporary folder and is removed when the screen closes; saving copies it into the library
/// (add-only permission).
@Observable @MainActor
final class MemoryVideoModel {
  enum Phase: Equatable {
    case planning
    case rendering(Double)
    case ready(URL)
    case failed(String)
    case cancelled
  }

  enum SaveState: Equatable {
    case idle, saving, saved
    case failed(String)
  }

  let request: VideoRequest
  private(set) var phase: Phase = .planning
  private(set) var save: SaveState = .idle
  private(set) var shots = 0
  private(set) var seconds = 0.0

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var file: URL?

  init(request: VideoRequest) { self.request = request }

  func start(app: AppModel) {
    guard task == nil else { return }
    let repositories = app.repositories, ids = request.ids
    let url = FileManager.default.temporaryDirectory
      .appending(path: "memories", directoryHint: .isDirectory)
      .appending(path: "\(UUID().uuidString).mp4")
    file = url
    // Holds the model until the render ends or is cancelled (`close()` cancels it).
    task = Task {
      do {
        let records = try await repositories.assets(ids: ids)
        let plan = MemoryReelPlanner.plan(candidates: MemoryReelInput.candidates(records: records),
                                          target: .standard)
        if let problem = plan.problem {
          phase = .failed(Self.text(problem))
          return
        }
        shots = plan.shots.count
        seconds = plan.duration
        phase = .rendering(0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wifi = await WiFi.isAvailable()
        let exporter = MemoryVideoExporter(source: PhotoKitReelSource(wifi: wifi))
        _ = try await exporter.export(plan, to: url) { progress in
          Task { @MainActor in self.progressed(progress) }
        }
        try Task.checkCancellation()
        phase = .ready(url)
      } catch is CancellationError {
        phase = .cancelled
      } catch {
        phase = Task.isCancelled ? .cancelled : .failed("The video couldn't be made. Try again.")
      }
    }
  }

  private func progressed(_ value: Double) {
    if case .rendering = phase { phase = .rendering(value) }
  }

  func cancel() {
    task?.cancel()
    phase = .cancelled
  }

  func saveToPhotos() async {
    guard case .ready(let url) = phase, save != .saving else { return }
    save = .saving
    do {
      try await VideoLibrarySaver.save(url)
      save = .saved
    } catch VideoLibrarySaver.Failure.notAllowed {
      save = .failed("Roll isn't allowed to add to Photos. You can allow it in Settings.")
    } catch {
      save = .failed("The video couldn't be saved. Try again.")
    }
  }

  /// The screen closed: stop rendering and remove the temporary file.
  func close() {
    task?.cancel()
    if let file { try? FileManager.default.removeItem(at: file) }
  }

  static func text(_ problem: ReelProblem) -> String {
    switch problem {
    case .notEnoughPhotos(let have, let need):
      "A memory video needs at least \(need) photos that aren't screenshots or near-duplicates. These have \(have)."
    }
  }
}
