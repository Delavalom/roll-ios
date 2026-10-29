import Foundation
import Testing
@testable import Monitor

struct LoadTests {
  @Test func handComputedTwoCores() {
    let prev = [CoreTicks(user: 100, system: 50, idle: 800, nice: 10),
                CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
    let now = [CoreTicks(user: 130, system: 70, idle: 880, nice: 20),   // busy 30+20+10 = 60, idle 80 -> 60/140
                CoreTicks(user: 10, system: 10, idle: 80, nice: 0)]     // busy 20, idle 80 -> 0.2
    let r = HostStats.load(prev: prev, now: now)
    #expect(r.perCore.count == 2)
    #expect(r.perCore[0] == 60.0 / 140.0)
    #expect(r.perCore[1] == 0.2)
    // total: busy 80 over all 240
    #expect(r.total == 80.0 / 240.0)
  }

  @Test func niceCountsAsBusy() {
    let r = HostStats.load(prev: [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)],
                           now: [CoreTicks(user: 0, system: 0, idle: 50, nice: 50)])
    #expect(r.total == 0.5)
    #expect(r.perCore == [0.5])
  }

  @Test func fullyBusyAndFullyIdle() {
    let z = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
    #expect(HostStats.load(prev: [z], now: [CoreTicks(user: 40, system: 60, idle: 0, nice: 0)]).total == 1)
    #expect(HostStats.load(prev: [z], now: [CoreTicks(user: 0, system: 0, idle: 100, nice: 0)]).total == 0)
  }

  @Test func noElapsedTicksReadsZero() {
    let t = [CoreTicks(user: 5, system: 5, idle: 5, nice: 5)]
    let r = HostStats.load(prev: t, now: t)
    #expect(r.total == 0)
    #expect(r.perCore == [0])
  }

  @Test func counterWraparoundUsesWrappingDelta() {
    let prev = [CoreTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
    let now = [CoreTicks(user: 10, system: 0, idle: 20, nice: 0)]   // user delta 20 across the wrap
    #expect(HostStats.load(prev: prev, now: now).total == 0.5)
  }

  @Test func mismatchedCoreCountsPairByIndex() {
    let z = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
    let r = HostStats.load(prev: [z], now: [CoreTicks(user: 1, system: 0, idle: 3, nice: 0), z])
    #expect(r.perCore == [0.25])
    #expect(HostStats.load(prev: [], now: []).perCore.isEmpty)
    #expect(HostStats.load(prev: [], now: []).total == 0)
  }
}

struct MemorySnapshotTests {
  private func snap(active: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, total: UInt64) -> MemorySnapshot {
    MemorySnapshot(free: 1_000, active: active, inactive: 2_000, wired: wired, compressed: compressed, total: total)
  }

  @Test func usedIsActivePlusWiredPlusCompressed() {
    let s = snap(active: 300, wired: 200, compressed: 100, total: 1_200)
    #expect(s.used == 600)
    #expect(s.usedFraction == 0.5)
  }

  @Test func freeAndInactiveAreNotUsed() {
    #expect(snap(total: 8_000).usedFraction == 0)
  }

  @Test func clampsToOne() {
    #expect(snap(active: 900, wired: 900, total: 1_000).usedFraction == 1)
  }

  @Test func zeroTotalIsZero() {
    #expect(snap(active: 5, total: 0).usedFraction == 0)
  }
}

struct TickParsingTests {
  @Test func readsStatesInMachOrder() {
    // Two cores, four states each, in CPU_STATE_USER/SYSTEM/IDLE/NICE slots.
    var info = [integer_t](repeating: 0, count: 2 * Int(CPU_STATE_MAX))
    func set(_ core: Int, _ state: Int32, _ v: integer_t) { info[core * Int(CPU_STATE_MAX) + Int(state)] = v }
    set(0, CPU_STATE_USER, 1); set(0, CPU_STATE_SYSTEM, 2); set(0, CPU_STATE_IDLE, 3); set(0, CPU_STATE_NICE, 4)
    set(1, CPU_STATE_USER, 5); set(1, CPU_STATE_SYSTEM, 6); set(1, CPU_STATE_IDLE, 7); set(1, CPU_STATE_NICE, 8)
    let ticks = info.withUnsafeBufferPointer { HostStats.parseTicks($0, cpuCount: 2) }
    #expect(ticks == [CoreTicks(user: 1, system: 2, idle: 3, nice: 4), CoreTicks(user: 5, system: 6, idle: 7, nice: 8)])
  }

  @Test func shortBufferIsRejectedNotReadPastTheEnd() {
    let info = [integer_t](repeating: 1, count: 2 * Int(CPU_STATE_MAX) - 1)
    #expect(info.withUnsafeBufferPointer { HostStats.parseTicks($0, cpuCount: 2) }.isEmpty)
  }

  @Test func negativeCountersReinterpretAsUnsigned() {
    let info: [integer_t] = [-1, 0, 0, 0]
    let ticks = info.withUnsafeBufferPointer { HostStats.parseTicks($0, cpuCount: 1) }
    #expect(ticks[0].user == UInt32.max)
  }
}

struct LiveReadingTests {
  @Test func memoryReadsAreSane() throws {
    let m = try #require(HostStats.memory())
    #expect(m.total == ProcessInfo.processInfo.physicalMemory)
    #expect(m.active > 0 && m.wired > 0)
    let pages = Double(m.free + m.active + m.inactive + m.wired + m.compressed)
    #expect(pages >= 0.5 * Double(m.total) && pages <= 1.05 * Double(m.total))
    #expect(m.usedFraction > 0 && m.usedFraction <= 1)
  }

  @Test func cpuTicksCoverEveryCore() {
    let ticks = HostStats.cpuTicks()
    #expect(ticks.count == ProcessInfo.processInfo.processorCount)
    #expect(ticks.allSatisfy { UInt64($0.user) + UInt64($0.system) + UInt64($0.idle) + UInt64($0.nice) > 0 })
  }

  @Test func repeatedCpuReadsDoNotLeakOrFail() {
    for _ in 0..<500 { #expect(!HostStats.cpuTicks().isEmpty) }
  }

  @Test func liveLoadStaysInRange() {
    let a = HostStats.cpuTicks()
    var x = 0.0
    for i in 0..<2_000_000 { x += Double(i).squareRoot() }
    #expect(x > 0)
    let r = HostStats.load(prev: a, now: HostStats.cpuTicks())
    #expect((0...1).contains(r.total))
    #expect(r.perCore.allSatisfy { (0...1).contains($0) })
  }
}
