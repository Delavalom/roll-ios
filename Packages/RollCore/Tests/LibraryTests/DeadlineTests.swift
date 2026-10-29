import Foundation
import Synchronization
import Testing
@testable import Library

/// A PhotoKit callback that never comes must not hold its caller up: `Deadline.answer` gives up after its timeout
/// (nil, "no answer") and cancels the operation, without waiting for it to end.
struct DeadlineTests {
  /// Never resumes on its own; holds its continuations so they don't leak mid-test.
  final class NeverAnswers: Sendable {
    private let waiting = Mutex<[CheckedContinuation<Int, Never>]>([])
    var calls: Int { waiting.withLock { $0.count } }
    func call() async -> Int {
      await withCheckedContinuation { c in waiting.withLock { $0.append(c) } }
    }
    func release() { waiting.withLock { $0 }.forEach { $0.resume(returning: 99) } }
  }

  @Test func anAnswerInTimeIsReturned() async {
    #expect(await Deadline.answer(within: .seconds(5)) { 7 } == 7)
    let optional: Bool?? = await Deadline.answer(within: .seconds(5)) { Bool?.none }
    #expect(optional == .some(nil), "the operation's own nil is an answer, not a timeout")
  }

  @Test func anOperationThatNeverCallsBackTimesOut() async {
    let hung = NeverAnswers()
    let start = ContinuousClock.now
    let value = await Deadline.answer(within: .milliseconds(50)) { await hung.call() }
    #expect(value == nil)
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(hung.calls == 1)
    hung.release()  // a late answer is ignored
  }

  @Test func theOperationIsCancelledAtTheDeadline() async throws {
    let sawCancel = Mutex(false)
    let value = await Deadline.answer(within: .milliseconds(30)) { () -> Int in
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
      sawCancel.withLock { $0 = true }
      return 1
    }
    #expect(value == nil)
    for _ in 0..<2000 where !sawCancel.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
    #expect(sawCancel.withLock { $0 })
  }

  @Test func cancellingTheCallerGivesUpAtOnce() async {
    let hung = NeverAnswers()
    let task = Task { await Deadline.answer(within: .seconds(60)) { await hung.call() } }
    while hung.calls == 0 { try? await Task.sleep(for: .milliseconds(1)) }
    task.cancel()
    #expect(await task.value == nil)
    hung.release()
  }
}
