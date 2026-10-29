import Foundation

/// `BackgroundTransport`'s bookkeeping, kept apart from `URLSession` so it is tested without a network: which task is
/// current for each destination key, who waits on it, failures found before a task completes, and the system's
/// background-events completion handlers. `Job` is the task (`URLSessionDownloadTask` in the app), compared by
/// identity. Not thread-safe: the transport keeps it in a `Mutex`.
struct TransportBook<Job: AnyObject, Waiter> {
  typealias Failure = TransportFailure

  private var waiters: [String: Waiter] = [:]
  private var current: [String: Job] = [:]
  /// Tasks this process replaced or gave up on: their late callbacks are ignored.
  private var retired: [Job] = []
  private var failures: [String: Failure] = [:]
  private var eventHandlers: [String: @Sendable () -> Void] = [:]
  /// Sessions whose events were all delivered before the system's handler arrived.
  private var finishedEvents: Set<String> = []

  // MARK: - Tasks

  /// `job` becomes the current task for `key` and `waiter` waits on it. Returns the waiter it replaces (to cancel).
  mutating func start(_ key: String, job: Job, waiter: Waiter) -> Waiter? {
    if let old = current[key], old !== job { retired.append(old) }
    current[key] = job
    return waiters.updateValue(waiter, forKey: key)
  }

  func job(for key: String) -> Job? { current[key] }

  /// This process stopped `job` (a task of the other session): nothing it reports counts any more. Returns the waiter
  /// if `job` was the current task, to cancel (its completion won't come through any more).
  mutating func retire(_ job: Job, key: String) -> Waiter? {
    if !retired.contains(where: { $0 === job }) { retired.append(job) }
    guard current[key] === job else { return nil }
    current[key] = nil
    failures[key] = nil
    return waiters.removeValue(forKey: key)
  }

  /// Whether `job`'s callbacks count: it is the current task for `key`, or none is and this process didn't give up on
  /// it (a task from an earlier launch, whose file still lands at its destination with nobody waiting).
  func accepts(_ job: Job, key: String) -> Bool {
    if let task = current[key] { return task === job }
    return !retired.contains { $0 === job }
  }

  /// The waiter to report `job`'s progress to; nil for a stale task.
  func waiter(for key: String, job: Job) -> Waiter? {
    accepts(job, key: key) ? waiters[key] : nil
  }

  /// Remembers why `job`'s file isn't usable; ignored for a stale task.
  mutating func fail(_ key: String, job: Job, _ failure: Failure) {
    if accepts(job, key: key) { failures[key] = failure }
  }

  /// `job` completed: the waiter to resume and the failure found on the way. nil for a stale task, which must not
  /// complete the current task's waiter.
  mutating func complete(_ key: String, job: Job) -> (waiter: Waiter?, failure: Failure?)? {
    guard accepts(job, key: key) else {
      retired.removeAll { $0 === job }  // a task completes once
      return nil
    }
    current[key] = nil
    return (waiters.removeValue(forKey: key), failures.removeValue(forKey: key))
  }

  // MARK: - Background events

  /// The system's completion handler for session `id`. Returns what to call now: the handler itself if the session's
  /// events already finished (the sessions exist from launch, so that can happen first), else the handler it
  /// replaces, if any.
  mutating func handleEvents(_ id: String, completion: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)? {
    if finishedEvents.remove(id) != nil { return completion }
    return eventHandlers.updateValue(completion, forKey: id)
  }

  /// Every event of session `id` was delivered: the handler to call, or nil, remembered so that a handler arriving
  /// later is called at once.
  mutating func eventsFinished(_ id: String) -> (@Sendable () -> Void)? {
    if let handler = eventHandlers.removeValue(forKey: id) { return handler }
    finishedEvents.insert(id)
    return nil
  }
}

/// Why a finished download's file isn't usable: found in `didFinishDownloadingTo`, thrown when the task completes.
enum TransportFailure: Error, Equatable, Sendable, CustomStringConvertible {
  case http(Int)
  case storage(String)

  var description: String {
    switch self {
    case .http(let status): "HTTP \(status)"
    case .storage(let why): why
    }
  }
}

/// What to do with resume data when a download resumed from it failed.
enum ResumeDecision: Equatable, Sendable {
  /// Rethrow and keep the resume data: the next attempt resumes from it.
  case keep
  /// The resume data doesn't work: delete it and download from the start.
  case startOver

  /// HTTP 4xx (an expired CDN URL) and failures that left no new resume data mean the old data is useless. A lost
  /// connection, a server error (5xx) or a cancellation say nothing against it.
  static func afterFailedResume(_ error: any Error) -> ResumeDecision {
    if error is CancellationError { return .keep }
    if let failure = error as? TransportFailure {
      if case .http(let status) = failure { return (400..<500).contains(status) ? .startOver : .keep }
      return .startOver
    }
    if let url = error as? URLError {
      if url.code == .cancelled || connectivity.contains(url.code) { return .keep }
      return url.downloadTaskResumeData == nil ? .startOver : .keep
    }
    return (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] is Data ? .keep : .startOver
  }

  private static let connectivity: Set<URLError.Code> = [
    .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
    .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
    .backgroundSessionWasDisconnected,
  ]
}
