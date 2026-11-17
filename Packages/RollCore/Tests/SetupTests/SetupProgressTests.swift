import Foundation
import Testing
@testable import Setup

/// One bar over the whole setup: the model's share, then photos read; long steps creep on a time estimate.
struct SetupProgressTests {
  @Test func eachStageHasItsShareOfTheBar() {
    #expect(SetupProgress.fraction(of: .unknown) == 0)
    #expect(SetupProgress.fraction(of: .model(.waiting(.wifi))) == 0)
    #expect(SetupProgress.fraction(of: .model(.downloading(completedBytes: 50, totalBytes: 100))) == 0.075)
    #expect(SetupProgress.fraction(of: .model(.installing)) == SetupProgress.downloadShare)
    #expect(SetupProgress.fraction(of: .model(.preparing(done: 0, total: 9))) == SetupProgress.installEnd)
    #expect(SetupProgress.fraction(of: .model(.preparing(done: 9, total: 9))) == SetupProgress.modelEnd)
    #expect(SetupProgress.fraction(of: .library(LibraryCounts(read: 0, total: 100))) == SetupProgress.modelEnd)
    #expect(abs(SetupProgress.fraction(of: .library(LibraryCounts(read: 50, total: 100))) - 0.675) < 1e-9)
    #expect(SetupProgress.fraction(of: .done(LibraryCounts(read: 3, total: 3))) == 1)
  }

  @Test func anEmptyLibraryOrUnknownSizeDoesNotDivideByZero() {
    #expect(SetupProgress.fraction(of: .model(.downloading(completedBytes: 10, totalBytes: 0))) == 0)
    #expect(SetupProgress.fraction(of: .model(.preparing(done: 0, total: 0))) == SetupProgress.installEnd)
    #expect(SetupProgress.fraction(of: .library(LibraryCounts(read: 0, total: 0))) == SetupProgress.modelEnd)
    #expect(LibraryCounts(read: 0, total: 0).isComplete)
  }

  @Test func countsAreClamped() {
    #expect(LibraryCounts(read: 12, total: 10) == LibraryCounts(read: 10, total: 10))
    #expect(LibraryCounts(read: -3, total: 10).read == 0)
    #expect(LibraryCounts(read: 5, total: -1) == LibraryCounts(read: 0, total: 0))
  }

  @Test func theCreepMovesButNeverReachesTheNextStep() {
    #expect(SetupProgress.creep(.zero, expected: .seconds(120)) == 0)
    let atExpected = SetupProgress.creep(.seconds(120), expected: .seconds(120))
    #expect(abs(atExpected - (1 - exp(-1))) < 1e-9)
    #expect(SetupProgress.creep(.seconds(10_000), expected: .seconds(120)) == 0.95)
    #expect(SetupProgress.creep(.milliseconds(500), expected: .seconds(120)) > 0, "sub-second time counts")

    // A function compiling for an hour stays below the next function's start.
    let one = SetupProgress.fraction(of: .model(.preparing(done: 0, total: 9)), elapsed: .seconds(3600))
    let next = SetupProgress.fraction(of: .model(.preparing(done: 1, total: 9)))
    #expect(one > SetupProgress.installEnd && one < next)
    let install = SetupProgress.fraction(of: .model(.installing), elapsed: .seconds(3600))
    #expect(install > SetupProgress.downloadShare && install < SetupProgress.installEnd)
  }
}
