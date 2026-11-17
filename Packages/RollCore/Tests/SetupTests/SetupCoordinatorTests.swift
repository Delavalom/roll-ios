import Foundation
import Testing
@testable import Setup

/// The coordinator sequences the model then the library, resumes from wherever the world stands, and runs while any
/// holder keeps a lease.
struct SetupCoordinatorTests {
  @Test func aFreshPhoneGoesFromTheDownloadToEveryPhotoRead() async {
    let work = FakeWork { $0.holdModel = true }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let recorder = await Recorder(setup)
    let running = Task { await setup.runHolding("foreground") }
    #expect(await eventually { await setup.progress.stage == .model(.preparing(done: 2, total: 2)) })
    #expect(await setup.progress.overall == SetupProgress.modelEnd)
    work.modelGate.open()
    let outcome = await running.value
    #expect(outcome == .finished(LibraryCounts(read: 10, total: 10)))
    #expect(await setup.progress == SetupProgress(stage: .done(LibraryCounts(read: 10, total: 10)), overall: 1))
    #expect(await setup.lastOutcome == outcome)
    #expect(await setup.isRunning == false)
    #expect(await eventually { recorder.all.last?.overall == 1 })
    let overall = recorder.all.map(\.overall)
    #expect(overall == overall.sorted(), "the bar never goes back: \(overall)")
    recorder.stop()
  }

  @Test func aRunDoesOnlyWhatIsMissing() async {
    let work = FakeWork {
      $0.modelReady = true
      $0.read = 5
    }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let recorder = await Recorder(setup)
    #expect(await setup.runHolding("foreground") == .finished(LibraryCounts(read: 10, total: 10)))
    #expect(work.state.withLock { $0.reportedSteps.isEmpty }, "an attached model reports no steps")
    #expect(await eventually { recorder.all.last?.overall == 1 })
    let libraryReads = recorder.all.compactMap { if case .library(let c) = $0.stage { c.read } else { nil } }
    #expect(libraryReads.allSatisfy { $0 >= 5 }, "it starts where the last run stopped: \(libraryReads)")
    recorder.stop()
  }

  @Test func aFinishedSetupChecksAndFinishesAtOnce() async {
    let work = FakeWork {
      $0.modelReady = true
      $0.read = 10
    }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    #expect(await setup.runHolding("foreground") == .finished(LibraryCounts(read: 10, total: 10)))
    #expect(work.state.withLock { $0.readLibraryCalls } == 0)
    #expect(work.state.withLock { $0.readyModelCalls } == 1, "the model is still asked: a purge or update shows here")
  }

  @Test func laterHoldersJoinTheRunAndTheLastReleaseStopsIt() async {
    let work = FakeWork { $0.holdLibraryAt = 4 }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    let continued = await setup.acquire("continued")
    #expect(await eventually { work.libraryGate.waiting == 1 })
    #expect(work.state.withLock { $0.readyModelCalls } == 1, "one run for both holders")
    #expect(await setup.isHeld(byOtherThan: "foreground"))

    await setup.release(front)
    #expect(await setup.isRunning, "the continued task still holds it")
    #expect(await setup.isHeld(byOtherThan: "foreground"))

    await setup.release(continued)
    #expect(await setup.outcome() == .stopped)
    #expect(await setup.isRunning == false)
    #expect(work.state.withLock { $0.read } == 4, "what was read stays read")

    // The next holder resumes: the model is skipped and the read picks up at 4.
    work.state.withLock { $0.holdLibraryAt = nil }
    #expect(await setup.runHolding("overnight") == .finished(LibraryCounts(read: 10, total: 10)))
    #expect(work.state.withLock { $0.reportedSteps.count } == 6, "the model's steps ran once")
  }

  @Test func aCancelledHolderLeavesAtOnceWhileAnotherKeepsTheRun() async {
    let work = FakeWork { $0.holdLibraryAt = 2 }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    let continued = Task { await setup.runHolding("continued") }
    #expect(await eventually { work.libraryGate.waiting == 1 })
    #expect(await eventually { await setup.isHeld(byOtherThan: "foreground") })
    continued.cancel()
    #expect(await continued.value == .stopped)
    #expect(await setup.isRunning, "the front still holds it")
    #expect(await setup.isHeld(byOtherThan: "foreground") == false)

    work.libraryGate.open()
    #expect(await setup.outcome() == .finished(LibraryCounts(read: 10, total: 10)))
    await setup.release(front)
  }

  @Test func aHolderWhoseRunEndsGetsItsOutcome() async {
    let work = FakeWork { $0.holdLibraryAt = 3 }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    let continued = Task { await setup.runHolding("continued") }
    #expect(await eventually { work.libraryGate.waiting == 1 })
    work.libraryGate.open()
    #expect(await continued.value == .finished(LibraryCounts(read: 10, total: 10)))
    #expect(await setup.isHeld(byOtherThan: "foreground") == false, "it gave its lease back")
    await setup.release(front)
  }

  @Test func reasonsThePersonCanActOnBlockTheRun() async {
    let space = FakeWork { $0.modelError = SetupBlockError(.notEnoughSpace(requiredBytes: 900)) }
    let setup = SetupCoordinator(work: space, clock: ManualClock().clock)
    #expect(await setup.runHolding("foreground") == .blocked(.notEnoughSpace(requiredBytes: 900)))
    #expect(space.state.withLock { $0.readLibraryCalls } == 0, "no library read without the model")

    let failing = FakeWork { $0.libraryError = Boom() }
    let other = SetupCoordinator(work: failing, clock: ManualClock().clock)
    #expect(await other.runHolding("overnight") == .blocked(.failed("boom")))
  }

  @Test func restartTriesAgainForTheHoldersStillThere() async {
    let work = FakeWork { $0.modelError = Boom() }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    #expect(await setup.outcome() == .blocked(.failed("boom")))
    #expect(await setup.isRunning == false)

    work.state.withLock { $0.modelError = nil }
    await setup.restart()
    #expect(await setup.outcome() == .finished(LibraryCounts(read: 10, total: 10)))
    await setup.release(front)

    await setup.restart()
    #expect(await setup.isRunning == false, "no holder, no run")
  }

  @Test func aHolderArrivingWhileAStoppedRunWindsDownGetsANewRun() async {
    let work = FakeWork { $0.holdLibraryAt = 3 }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    #expect(await eventually { work.libraryGate.waiting == 1 })
    await setup.release(front)  // cancels; the run hasn't ended yet
    let overnight = Task { await setup.runHolding("overnight") }
    work.libraryGate.open()
    #expect(await overnight.value == .finished(LibraryCounts(read: 10, total: 10)))
  }

  @Test func aLongCompileCreepsForwardAndNeverGoesBack() async {
    let time = ManualClock()
    let work = FakeWork {
      $0.modelSteps = [.installing, .preparing(done: 0, total: 4)]
      $0.holdModel = true
    }
    let setup = SetupCoordinator(work: work, clock: time.clock)
    let front = await setup.acquire("foreground")
    #expect(await eventually { work.modelGate.waiting == 1 })
    #expect(await eventually { await setup.progress.stage == .model(.preparing(done: 0, total: 4)) })
    let start = await setup.progress.overall
    #expect(start == SetupProgress.installEnd)

    time.advance(.seconds(120))
    #expect(await eventually { await setup.progress.overall > start }, "the ticker moves it without a report")
    let moved = await setup.progress.overall
    let nextFunction = SetupProgress.fraction(of: .model(.preparing(done: 1, total: 4)))
    #expect(moved < nextFunction)

    time.advance(.seconds(100_000))
    #expect(await eventually { await setup.progress.overall > moved })
    #expect(await setup.progress.overall < nextFunction)

    await setup.release(front)
    #expect(await setup.outcome() == .stopped)
  }

  @Test func aNewRunStartsItsOwnBar() async {
    let work = FakeWork {
      $0.modelReady = true
      $0.read = 10
    }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    #expect(await setup.outcome() == .finished(LibraryCounts(read: 10, total: 10)))
    #expect(await setup.progress.overall == 1)

    // New photos arrive: the next run reads them and its bar shows where it is, not the last run's 1.
    work.state.withLock {
      $0.total = 20
      $0.holdLibraryAt = 12
    }
    await setup.restart()
    #expect(await eventually { work.libraryGate.waiting == 1 })
    #expect(await eventually { await setup.progress.stage == .library(LibraryCounts(read: 12, total: 20)) })
    #expect(await setup.progress.overall < 1)
    work.libraryGate.open()
    #expect(await setup.outcome() == .finished(LibraryCounts(read: 20, total: 20)))
    await setup.release(front)
  }

  @Test func aRunCancelledAsItReachesTheLibraryNeverReadsAsFinished() async {
    // The model step can't be interrupted: it returns normally after the cancel, and the count that follows
    // fails as database reads do in a cancelled task. The run stops; it doesn't finish with 0 of 0.
    let work = FakeWork {
      $0.modelSteps = [.installing]
      $0.holdModel = true
      $0.modelIgnoresCancel = true
    }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    #expect(await eventually { work.modelGate.waiting == 1 })
    await setup.release(front)
    #expect(await setup.outcome() == .stopped)
    #expect(await setup.progress.stage != .done(LibraryCounts(read: 0, total: 0)))
  }

  @Test func aRunThatStopsByItselfIsNotRestartedForever() async {
    let work = FakeWork { $0.modelThrowsCancellation = true }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    #expect(await setup.outcome() == .stopped)
    #expect(await setup.isRunning == false, "not cancelled by a release: no restart")
    #expect(work.state.withLock { $0.readyModelCalls } == 1)
    await setup.release(front)
  }

  @Test func aNewRunPublishesNothingUntilItReports() async {
    let work = FakeWork {
      $0.modelReady = true
      $0.read = 10
    }
    // A real ticker: before its first report, the new run must not republish the last run's `.done` at 1 (that
    // would pin this run's bar at 1 while it reads new photos).
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock, tick: .milliseconds(1))
    let front = await setup.acquire("foreground")
    #expect(await setup.outcome() == .finished(LibraryCounts(read: 10, total: 10)))
    work.state.withLock {
      $0.modelReady = false
      $0.modelSteps = []
      $0.holdModel = true
      $0.total = 20
      $0.holdLibraryAt = 12
    }
    await setup.restart()
    #expect(await eventually { work.modelGate.waiting == 1 })
    try? await Task.sleep(for: .milliseconds(20))  // the ticker ticks while the model step reports nothing
    work.modelGate.open()
    #expect(await eventually { await setup.progress.stage == .library(LibraryCounts(read: 12, total: 20)) })
    #expect(await setup.progress.overall < 1)
    work.libraryGate.open()
    #expect(await setup.outcome() == .finished(LibraryCounts(read: 20, total: 20)))
    await setup.release(front)
  }

  @Test func releasingTwiceOrAStrangersLeaseIsHarmless() async {
    let work = FakeWork { $0.holdLibraryAt = 1 }
    let setup = SetupCoordinator(work: work, clock: ManualClock().clock)
    let front = await setup.acquire("foreground")
    #expect(await eventually { work.libraryGate.waiting == 1 })
    await setup.release(SetupLease(id: UUID(), holder: "foreground"))
    #expect(await setup.isRunning)
    await setup.release(front)
    await setup.release(front)
    #expect(await setup.outcome() == .stopped)
  }
}
