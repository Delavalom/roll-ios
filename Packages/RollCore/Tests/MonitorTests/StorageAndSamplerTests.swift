import Foundation
import Testing
@testable import Monitor

struct StorageStatsTests {
  @Test func availableIsAtMostTotal() throws {
    let s = try StorageStats.snapshot()
    #expect(s.total > 0)
    #expect(s.available >= 0)
    #expect(s.available <= s.total)
    #expect((0...1).contains(s.usedFraction))
  }

  @Test func missingValueNamesTheKey() throws {
    #expect(throws: StorageStats.MissingValue(key: .volumeTotalCapacityKey)) {
      try StorageStats.snapshot(total: nil, available: 5)
    }
    #expect(throws: StorageStats.MissingValue(key: .volumeAvailableCapacityForImportantUsageKey)) {
      try StorageStats.snapshot(total: 100, available: nil)
    }
    #expect(try StorageStats.snapshot(total: 100, available: 40) == StorageSnapshot(total: 100, available: 40))
  }

  @Test func usedFractionArithmetic() {
    #expect(StorageSnapshot(total: 1_000, available: 250).usedFraction == 0.75)
    #expect(StorageSnapshot(total: 0, available: 0).usedFraction == 0)
    #expect(StorageSnapshot(total: 100, available: 400).usedFraction == 0)
  }
}

@MainActor
struct DeviceSamplerTests {
  /// Polls until `condition` holds or five seconds pass; no fixed sleeps.
  private func wait(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
  }

  @Test func ringBufferKeepsNewestSixty() {
    let sampler = DeviceSampler()
    for i in 0..<75 {
      sampler.append(DeviceSample(date: Date(timeIntervalSince1970: Double(i)), ramUsedFraction: 0.5, cpuTotal: 0))
    }
    #expect(sampler.samples.count == 60)
    #expect(sampler.samples.first?.date == Date(timeIntervalSince1970: 15))
    #expect(sampler.samples.last?.date == Date(timeIntervalSince1970: 74))
  }

  @Test func firstSampleHasNoCpuValueLaterOnesDo() {
    let sampler = DeviceSampler()
    sampler.start()
    #expect(sampler.samples.count == 1)
    #expect(sampler.samples[0].cpuTotal == nil)
    #expect(sampler.perCoreLoad.isEmpty)
    #expect(sampler.samples[0].ramUsedFraction != nil)
    sampler.sample()
    let second = sampler.samples[1]
    if let cpu = second.cpuTotal { #expect((0...1).contains(cpu)) } else { Issue.record("cpu missing on second sample") }
    #expect(sampler.perCoreLoad.count == ProcessInfo.processInfo.processorCount)
    if let ram = second.ramUsedFraction { #expect(ram > 0 && ram <= 1) } else { Issue.record("ram missing") }
    #expect(sampler.uptime > 0)
    sampler.stop()
  }

  @Test func startIsIdempotentAndLoopKeepsSampling() async {
    let sampler = DeviceSampler(interval: .milliseconds(10))
    sampler.start()
    sampler.start()
    #expect(sampler.isRunning)
    #expect(sampler.samples.count == 1)
    await wait { sampler.samples.count >= 4 }
    #expect(sampler.samples.count >= 4)
    sampler.stop()
  }

  @Test func stopCancelsLoopAndClearsHistory() async {
    let sampler = DeviceSampler(interval: .milliseconds(10))
    sampler.start()
    await wait { sampler.samples.count >= 3 }
    sampler.stop()
    #expect(!sampler.isRunning)
    #expect(sampler.samples.isEmpty)
    #expect(sampler.perCoreLoad.isEmpty)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(sampler.samples.isEmpty)
  }

  @Test func releasingARunningSamplerDoesNotLeakIt() async {
    var sampler: DeviceSampler? = DeviceSampler(interval: .milliseconds(10))
    weak let weakSampler = sampler
    sampler?.start()
    sampler = nil
    await wait { weakSampler == nil }
    #expect(weakSampler == nil)
  }

  @Test func restartAfterStopSkipsCpuOnceMore() {
    let sampler = DeviceSampler()
    sampler.start(); sampler.sample(); sampler.stop()
    sampler.start()
    #expect(sampler.samples.count == 1)
    #expect(sampler.samples[0].cpuTotal == nil)
    sampler.stop()
  }

  @Test func deadlinesStaySteadyWhenASampleRunsLong() {
    let start = ContinuousClock.now
    let interval = Duration.milliseconds(100)
    // Late by half an interval: the next deadline is the following grid point, not now + interval.
    let next = DeviceSampler.nextDeadline(after: start + interval, now: start + interval + .milliseconds(50), interval: interval)
    #expect(next == start + interval * 2)
    // Very late: skip missed ticks rather than firing a burst.
    let skipped = DeviceSampler.nextDeadline(after: start + interval, now: start + .milliseconds(450), interval: interval)
    #expect(skipped == start + .milliseconds(500))
  }
}
