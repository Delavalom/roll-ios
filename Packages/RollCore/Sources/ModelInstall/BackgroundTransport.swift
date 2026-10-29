import Foundation
import Synchronization

/// `ModelTransport` over background `URLSession`s: the download goes on while Roll is suspended or was ended by the
/// system, and iOS relaunches Roll in the background when it finishes (`handleEvents`). Two sessions, because the
/// network policy is per session (`DownloadPolicy`): the default one allows no cellular, no personal hotspot and no
/// Low Data Mode, so it waits (and pauses) by itself; the other allows all of them, only after the person asked.
///
/// Tasks are named by their destination relative to `root` (the app container's path can change between launches),
/// so a call after a relaunch reattaches to the running task instead of starting another one, and a file that
/// finished while nobody waited lands at its destination anyway. Interrupted downloads keep resume data next to the
/// destination (`.resume`); resume data that no longer works (an HTTP 4xx from an expired CDN URL, or a failure that
/// left no new resume data) is dropped once and the file is downloaded from the start, while a lost connection keeps
/// it (`ResumeDecision`). Only the current task for a destination moves its file there or completes its waiter.
/// The bookkeeping is `TransportBook`, tested without a network; this class only wires it to `URLSession`.
public final class BackgroundTransport: NSObject, ModelTransport, URLSessionDownloadDelegate, Sendable {
  public static let wifiIdentifier = "com.delavalom.roll.model.wifi"
  public static let anyNetworkIdentifier = "com.delavalom.roll.model.any"

  /// One per process: a background session identifier may have only one `URLSession`. Create it at launch, before
  /// `handleEvents` can be called.
  public static let shared = BackgroundTransport(root: ModelInstaller.defaultRoot)

  private struct Waiter {
    let continuation: CheckedContinuation<Void, any Error>
    let progress: @Sendable (Int64) -> Void
  }

  private let root: URL
  private let book = Mutex(TransportBook<URLSessionDownloadTask, Waiter>())
  private let sessions = Mutex<[String: URLSession]>([:])

  init(root: URL) {
    self.root = root
    super.init()
    for (id, cellular) in [(Self.wifiIdentifier, false), (Self.anyNetworkIdentifier, true)] {
      let config = URLSessionConfiguration.background(withIdentifier: id)
      config.allowsCellularAccess = cellular
      config.allowsExpensiveNetworkAccess = cellular
      config.allowsConstrainedNetworkAccess = cellular
      config.isDiscretionary = false  // someone is waiting for it
      config.sessionSendsLaunchEvents = true
      let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
      sessions.withLock { $0[id] = session }
    }
  }

  private func session(allowCellular: Bool) -> URLSession {
    sessions.withLock { $0[allowCellular ? Self.anyNetworkIdentifier : Self.wifiIdentifier]! }
  }

  /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. Returns false for other sessions.
  /// `completion` is called on the main queue: at once if the session's events were already delivered (the sessions
  /// are created at launch, so they can finish first), else when they are; a handler it replaces is called too.
  public func handleEvents(forSession identifier: String, completion: @escaping @Sendable () -> Void) -> Bool {
    guard sessions.withLock({ $0[identifier] != nil }) else { return false }
    if let now = book.withLock({ $0.handleEvents(identifier, completion: completion) }) {
      DispatchQueue.main.async { now() }
    }
    return true
  }

  // MARK: - ModelTransport

  public func download(_ url: URL, to destination: URL, allowCellular: Bool,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
    do { try await run(url, to: destination, allowCellular: allowCellular, progress: progress) } catch {
      if let failure = error as? TransportFailure { throw ModelInstallError.downloadFailed(failure.description) }
      throw error
    }
  }

  private func run(_ url: URL, to destination: URL, allowCellular: Bool,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
    let key = key(for: destination)
    let session = session(allowCellular: allowCellular)
    // A task from an earlier launch in the other session: stop it, keeping its resume data for this one.
    let other = self.session(allowCellular: !allowCellular)
    for task in await other.allTasks where task.taskDescription == key {
      await cancelKeepingResumeData(task as? URLSessionDownloadTask, key: key)
    }
    let running = await session.allTasks.first {
      $0.taskDescription == key && ($0.state == .running || $0.state == .suspended)
    } as? URLSessionDownloadTask
    let resumeFile = resumeURL(key)
    if running == nil, let data = try? Data(contentsOf: resumeFile) {
      do { return try await attempt(key, session: session, start: .resume(data), progress: progress) } catch {
        guard ResumeDecision.afterFailedResume(error) == .startOver else { throw error }
        try? FileManager.default.removeItem(at: resumeFile)
      }
    }
    try await attempt(key, session: session, start: running.map { .attach($0) } ?? .fresh(url), progress: progress)
  }

  private enum Start {
    case fresh(URL)
    case resume(Data)
    case attach(URLSessionDownloadTask)
  }

  private func attempt(_ key: String, session: URLSession, start: Start,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let task: URLSessionDownloadTask
        switch start {
        case .fresh(let url): task = session.downloadTask(with: url)
        case .resume(let data): task = session.downloadTask(withResumeData: data)
        case .attach(let existing): task = existing
        }
        task.taskDescription = key
        let waiter = Waiter(continuation: continuation, progress: progress)
        let replaced = book.withLock { $0.start(key, job: task, waiter: waiter) }
        replaced?.continuation.resume(throwing: CancellationError())
        task.resume()
        if Task.isCancelled { task.cancel(byProducingResumeData: { [weak self] data in self?.saveResume(data, key: key) }) }
      }
    } onCancel: {
      let task = book.withLock { $0.job(for: key) }
      task?.cancel(byProducingResumeData: { [weak self] data in self?.saveResume(data, key: key) })
    }
  }

  private func cancelKeepingResumeData(_ task: URLSessionDownloadTask?, key: String) async {
    guard let task else { return }
    book.withLock { $0.retire(task, key: key) }?.continuation.resume(throwing: CancellationError())
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      task.cancel(byProducingResumeData: { [weak self] data in
        self?.saveResume(data, key: key)
        done.resume()
      })
    }
  }

  // MARK: - URLSessionDownloadDelegate

  public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                         totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let key = downloadTask.taskDescription else { return }
    book.withLock { $0.waiter(for: key, job: downloadTask) }?.progress(totalBytesWritten)
  }

  /// The temporary file is deleted when this returns, so it is moved to its destination here, waiter or not. A task
  /// that isn't the current one for its destination (replaced, or given up on) leaves the destination alone.
  public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                         didFinishDownloadingTo location: URL) {
    guard let key = downloadTask.taskDescription, book.withLock({ $0.accepts(downloadTask, key: key) }) else { return }
    if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      book.withLock { $0.fail(key, job: downloadTask, .http(http.statusCode)) }
      return
    }
    let destination = destination(for: key)
    do {
      let fm = FileManager.default
      try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: destination)
      try fm.moveItem(at: location, to: destination)
      try? fm.removeItem(at: resumeURL(key))
    } catch {
      book.withLock { $0.fail(key, job: downloadTask, .storage(error.localizedDescription)) }
    }
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    guard let key = task.taskDescription, let download = task as? URLSessionDownloadTask,
          let (waiter, failure) = book.withLock({ $0.complete(key, job: download) }) else { return }
    // Only the current task's resume data: a replaced or given-up task's would overwrite newer data.
    if let data = (error as? NSError)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
      saveResume(data, key: key)
    }
    guard let waiter else { return }
    if let error {
      let cancelled = (error as? URLError)?.code == .cancelled
      waiter.continuation.resume(throwing: cancelled ? CancellationError() : error)
    } else if let failure {
      waiter.continuation.resume(throwing: failure)
    } else {
      waiter.continuation.resume()
    }
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let id = session.configuration.identifier,
          let handler = book.withLock({ $0.eventsFinished(id) }) else { return }
    DispatchQueue.main.async { handler() }
  }

  // MARK: - Paths

  private func key(for destination: URL) -> String {
    let base = root.standardizedFileURL.path + "/", path = destination.standardizedFileURL.path
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
  }

  private func destination(for key: String) -> URL {
    key.hasPrefix("/") ? URL(fileURLWithPath: key) : root.appending(path: key)
  }

  private func resumeURL(_ key: String) -> URL { destination(for: key).appendingPathExtension("resume") }

  private func saveResume(_ data: Data?, key: String) {
    guard let data else { return }
    let url = resumeURL(key)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}
