import Foundation
import Synchronization
@testable import Setup

/// Opens once; waiters before and after pass. Cancelling a waiter throws `CancellationError`.
final class Gate: Sendable {
  private struct State {
    var open = false
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var cancelled: Set<UUID> = []
  }

  private let state = Mutex(State())

  func open() {
    let waiting = state.withLock { s in
      s.open = true
      defer { s.waiters = [:] }
      return s.waiters
    }
    for continuation in waiting.values { continuation.resume() }
  }

  var waiting: Int { state.withLock { $0.waiters.count } }

  func wait() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let now: Result<Void, any Error>? = state.withLock { s in
          if s.cancelled.contains(id) { return .failure(CancellationError()) }
          if s.open { return .success(()) }
          s.waiters[id] = continuation
          return nil
        }
        if let now { continuation.resume(with: now) }
      }
    } onCancel: {
      let continuation = state.withLock { s in
        s.cancelled.insert(id)
        return s.waiters.removeValue(forKey: id)
      }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

struct Boom: Error, CustomStringConvertible {
  var description: String { "boom" }
}

/// The app's work, scripted: model steps to report, a library to read one photo at a time, and gates to hold either.
final class FakeWork: SetupWork {
  struct State {
    var modelReady = false
    var modelSteps: [ModelStep] = [
      .downloading(completedBytes: 0, totalBytes: 100), .downloading(completedBytes: 100, totalBytes: 100),
      .installing, .preparing(done: 0, total: 2), .preparing(done: 1, total: 2), .preparing(done: 2, total: 2),
    ]
    var modelError: (any Error)?
    /// Hold the model after its steps until `modelGate` opens.
    var holdModel = false
    var read = 0
    var total = 10
    var libraryError: (any Error)?
    /// Hold the library read when this many are read, until `libraryGate` opens.
    var holdLibraryAt: Int?
    var readyModelCalls = 0
    /// Ignore cancellation in `readyModel` and return normally (a step that can't be interrupted).
    var modelIgnoresCancel = false
    /// `readyModel` throws CancellationError without being cancelled (the app gone, say).
    var modelThrowsCancellation = false
    var readLibraryCalls = 0
    var reportedSteps: [ModelStep] = []
  }

  let state: Mutex<State>
  let modelGate = Gate()
  let libraryGate = Gate()

  init(_ configure: (inout State) -> Void = { _ in }) {
    var s = State()
    configure(&s)
    state = Mutex(s)
  }

  func readyModel(report: @escaping @Sendable (ModelStep) -> Void) async throws {
    let (ready, steps, hold) = state.withLock { s in
      s.readyModelCalls += 1
      return (s.modelReady, s.modelSteps, s.holdModel)
    }
    if ready { return }
    if state.withLock({ $0.modelThrowsCancellation }) { throw CancellationError() }
    for step in steps {
      try Task.checkCancellation()
      state.withLock { $0.reportedSteps.append(step) }
      report(step)
    }
    if hold {
      if state.withLock({ $0.modelIgnoresCancel }) { try? await modelGate.wait() } else { try await modelGate.wait() }
    }
    if let error = state.withLock({ $0.modelError }) { throw error }
    state.withLock { $0.modelReady = true }
  }

  func libraryCounts() async throws -> LibraryCounts {
    if Task.isCancelled { throw CancellationError() }  // as a database read in a cancelled task does
    return state.withLock { LibraryCounts(read: $0.read, total: $0.total) }
  }

  func readLibrary(report: @escaping @Sendable (LibraryCounts) -> Void) async throws {
    state.withLock { $0.readLibraryCalls += 1 }
    while true {
      try Task.checkCancellation()
      let (read, total, holdAt) = state.withLock { ($0.read, $0.total, $0.holdLibraryAt) }
      if read >= total { return }
      if let holdAt, read == holdAt {
        try await libraryGate.wait()
        state.withLock { $0.holdLibraryAt = nil }
      }
      if let error = state.withLock({ $0.libraryError }) { throw error }
      let counts = state.withLock { s in
        s.read += 1
        return LibraryCounts(read: s.read, total: s.total)
      }
      report(counts)
      await Task.yield()
    }
  }
}

/// A clock whose time moves only when a test says so; sleeps are a real millisecond so tickers spin gently.
final class ManualClock: Sendable {
  private let time = Mutex(Duration.zero)

  func advance(_ by: Duration) { time.withLock { $0 += by } }

  var clock: SetupCoordinator.Clock {
    SetupCoordinator.Clock(now: { self.time.withLock { $0 } }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
  }
}

/// Polls `condition` until it holds (2 s at most).
func eventually(_ what: String = "condition", _ condition: () async -> Bool) async -> Bool {
  for _ in 0..<2000 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return false
}

/// Collects everything a coordinator publishes.
final class Recorder: Sendable {
  private let values = Mutex<[SetupProgress]>([])
  private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

  init(_ coordinator: SetupCoordinator) async {
    let stream = await coordinator.progressUpdates()
    let task = Task { [weak self] in
      for await value in stream { self?.values.withLock { $0.append(value) } }
    }
    self.task.withLock { $0 = task }
  }

  var all: [SetupProgress] { values.withLock { $0 } }

  func stop() { task.withLock { $0?.cancel() } }
}
