import Foundation
import Synchronization
import Testing
@testable import ModelInstall

/// `BackgroundTransport`'s bookkeeping without `URLSession`: jobs stand in for download tasks, strings for waiters.
struct TransportBookTests {
  private final class Job {}
  private typealias Book = TransportBook<Job, String>

  /// Counts its calls.
  private final class Handler: Sendable {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    var call: @Sendable () -> Void { { [self] in count.withLock { $0 += 1 } } }
  }

  // MARK: - Background events

  @Test func aHandlerStoredBeforeTheEventsFinishIsCalledWhenTheyDo() {
    var book = Book()
    let handler = Handler()
    let early = book.handleEvents("s", completion: handler.call)
    #expect(early == nil)
    book.eventsFinished("s")?()
    #expect(handler.calls == 1)
    let again = book.eventsFinished("s")
    #expect(again == nil)  // called once
  }

  @Test func eventsThatFinishedBeforeTheHandlerArrivedCallItAtOnce() {
    var book = Book()
    let handler = Handler()
    let none = book.eventsFinished("s")
    #expect(none == nil)
    book.handleEvents("s", completion: handler.call)?()
    #expect(handler.calls == 1)

    // That finish is used up: the next handler waits for the next finish.
    let next = Handler()
    let now = book.handleEvents("s", completion: next.call)
    #expect(now == nil)
    #expect(next.calls == 0)
  }

  @Test func aReplacedHandlerIsReturnedToBeCalled() {
    var book = Book()
    let first = Handler(), second = Handler()
    let none = book.handleEvents("s", completion: first.call)
    #expect(none == nil)
    book.handleEvents("s", completion: second.call)?()
    #expect(first.calls == 1)
    book.eventsFinished("s")?()
    #expect(second.calls == 1)
    #expect(first.calls == 1)
  }

  @Test func sessionsAreKeptApart() {
    var book = Book()
    let wifi = Handler()
    _ = book.eventsFinished("any")
    let now = book.handleEvents("wifi", completion: wifi.call)
    #expect(now == nil)
    #expect(wifi.calls == 0)
  }

  // MARK: - Tasks and waiters

  @Test func aNewTaskReplacesTheWaiterAndRetiresTheOldTask() {
    var book = Book()
    let old = Job(), new = Job()
    let none = book.start("k", job: old, waiter: "first")
    let replaced = book.start("k", job: new, waiter: "second")
    #expect(none == nil)
    #expect(replaced == "first")

    #expect(!book.accepts(old, key: "k"))
    let stale = book.complete("k", job: old)
    #expect(stale == nil)  // must not complete the new task's waiter
    let done = book.complete("k", job: new)
    #expect(done?.waiter == "second")
    #expect(done?.failure == nil)
  }

  @Test func aReplacedTaskStaysStaleOnceTheCurrentOneCompleted() {
    var book = Book()
    let old = Job(), new = Job()
    _ = book.start("k", job: old, waiter: "first")
    _ = book.start("k", job: new, waiter: "second")
    let current = book.complete("k", job: new)
    #expect(current != nil)

    #expect(!book.accepts(old, key: "k"))  // its late file must not land on the destination
    book.fail("k", job: old, .http(500))
    let late = book.complete("k", job: old)
    #expect(late == nil)
  }

  @Test func aTaskFromAnEarlierLaunchIsAcceptedWithNobodyWaiting() {
    var book = Book()
    let orphan = Job()
    #expect(book.accepts(orphan, key: "k"))
    #expect(book.waiter(for: "k", job: orphan) == nil)
    let done = book.complete("k", job: orphan)
    #expect(done != nil)
    #expect(done?.waiter == nil)
  }

  @Test func aRetiredTaskFromTheOtherSessionIsIgnored() {
    var book = Book()
    let other = Job()
    let waiter = book.retire(other, key: "k")
    #expect(waiter == nil)
    #expect(!book.accepts(other, key: "k"))
    let done = book.complete("k", job: other)
    #expect(done == nil)
  }

  @Test func retiringTheCurrentTaskHandsBackItsWaiter() {
    var book = Book()
    let job = Job()
    _ = book.start("k", job: job, waiter: "w")
    let waiter = book.retire(job, key: "k")
    #expect(waiter == "w")  // to cancel: its completion no longer counts
    #expect(book.job(for: "k") == nil)
    let done = book.complete("k", job: job)
    #expect(done == nil)
  }

  @Test func progressGoesOnlyToTheCurrentTasksWaiter() {
    var book = Book()
    let old = Job(), new = Job()
    _ = book.start("k", job: old, waiter: "first")
    _ = book.start("k", job: new, waiter: "second")
    #expect(book.waiter(for: "k", job: new) == "second")
    #expect(book.waiter(for: "k", job: old) == nil)
  }

  @Test func aFailureFoundBeforeCompletionIsReportedWithIt() {
    var book = Book()
    let job = Job()
    _ = book.start("k", job: job, waiter: "w")
    book.fail("k", job: job, .http(403))
    let done = book.complete("k", job: job)
    #expect(done?.failure == .http(403))
    let retry = Job()
    _ = book.start("k", job: retry, waiter: "again")
    let second = book.complete("k", job: retry)
    #expect(second?.waiter == "again")
    #expect(second?.failure == nil)  // the old failure was reported once
  }

  @Test func keysAreIndependent() {
    var book = Book()
    let a = Job(), b = Job()
    _ = book.start("a", job: a, waiter: "wa")
    _ = book.start("b", job: b, waiter: "wb")
    let doneA = book.complete("a", job: a)
    #expect(doneA?.waiter == "wa")
    #expect(book.accepts(b, key: "b"))
    let doneB = book.complete("b", job: b)
    #expect(doneB?.waiter == "wb")
  }

  // MARK: - Resume or start over

  @Test(arguments: [403, 404, 410, 416])
  func anHTTPClientErrorStartsOver(_ status: Int) {
    #expect(ResumeDecision.afterFailedResume(TransportFailure.http(status)) == .startOver)
  }

  @Test func aServerErrorKeepsTheResumeData() {
    #expect(ResumeDecision.afterFailedResume(TransportFailure.http(503)) == .keep)
  }

  @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                    .dataNotAllowed])
  func aLostConnectionKeepsTheResumeData(_ code: URLError.Code) {
    #expect(ResumeDecision.afterFailedResume(URLError(code)) == .keep)
  }

  @Test func aCancellationKeepsTheResumeData() {
    #expect(ResumeDecision.afterFailedResume(CancellationError()) == .keep)
    #expect(ResumeDecision.afterFailedResume(URLError(.cancelled)) == .keep)
  }

  @Test func aFailureThatLeftNoNewResumeDataStartsOver() {
    #expect(ResumeDecision.afterFailedResume(URLError(.cannotDecodeRawData)) == .startOver)
    #expect(ResumeDecision.afterFailedResume(TransportFailure.storage("disk")) == .startOver)
    #expect(ResumeDecision.afterFailedResume(NSError(domain: "x", code: 1)) == .startOver)
  }

  @Test func aFailureWithNewResumeDataKeepsIt() {
    let info = [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)]
    #expect(ResumeDecision.afterFailedResume(URLError(.cannotDecodeRawData, userInfo: info)) == .keep)
    #expect(ResumeDecision.afterFailedResume(NSError(domain: "x", code: 1, userInfo: info)) == .keep)
  }
}
