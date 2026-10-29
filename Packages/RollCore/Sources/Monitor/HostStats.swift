import Darwin
import Foundation

/// Physical-memory pages by state, in bytes, plus the device total.
public struct MemorySnapshot: Sendable, Equatable {
  public var free: UInt64
  public var active: UInt64
  public var inactive: UInt64
  public var wired: UInt64
  public var compressed: UInt64
  public var total: UInt64

  public init(free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, total: UInt64) {
    self.free = free; self.active = active; self.inactive = inactive
    self.wired = wired; self.compressed = compressed; self.total = total
  }

  /// Memory the system cannot hand back without work: active + wired + compressed.
  /// Free and inactive pages count as available.
  public var used: UInt64 { active &+ wired &+ compressed }

  /// `used / total`, clamped to 0...1. Zero when the total is unknown.
  public var usedFraction: Double {
    guard total > 0 else { return 0 }
    return min(1, Double(used) / Double(total))
  }
}

/// Cumulative scheduler ticks for one core since boot.
public struct CoreTicks: Sendable, Equatable {
  public var user: UInt32
  public var system: UInt32
  public var idle: UInt32
  public var nice: UInt32

  public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
    self.user = user; self.system = system; self.idle = idle; self.nice = nice
  }
}

/// Read-only readings from the Mach host. Nothing here changes how the device runs (ADR-0002).
public enum HostStats {
  /// `mach_host_self()` hands out a new send right on every call, so take it once.
  private static let host = mach_host_self()

  /// Current memory by state. Returns `nil` if the kernel call fails.
  public static func memory() -> MemorySnapshot? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let status = withUnsafeMutablePointer(to: &stats) { statsPtr in
      statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    var pageSize: vm_size_t = 0
    guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
    let page = UInt64(pageSize)
    return MemorySnapshot(
      free: UInt64(stats.free_count) * page,
      active: UInt64(stats.active_count) * page,
      inactive: UInt64(stats.inactive_count) * page,
      wired: UInt64(stats.wire_count) * page,
      compressed: UInt64(stats.compressor_page_count) * page,
      total: ProcessInfo.processInfo.physicalMemory)
  }

  /// Cumulative ticks per core. Empty if the kernel call fails.
  public static func cpuTicks() -> [CoreTicks] {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
    guard status == KERN_SUCCESS, let info else { return [] }
    // The kernel allocated `info` in our address space; it must be released.
    defer {
      vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                    vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
    }
    return parseTicks(UnsafeBufferPointer(start: info, count: Int(infoCount)), cpuCount: Int(cpuCount))
  }

  /// Reads `cpuCount` rows of `CPU_STATE_MAX` counters. Returns `[]` if the buffer is too short for that.
  /// Counters are signed 32-bit in the kernel interface but cumulative, so they are reinterpreted as unsigned.
  static func parseTicks(_ info: UnsafeBufferPointer<integer_t>, cpuCount: Int) -> [CoreTicks] {
    let stride = Int(CPU_STATE_MAX)
    guard cpuCount > 0, info.count >= cpuCount * stride else { return [] }
    return (0..<cpuCount).map { core in
      let base = core * stride
      return CoreTicks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                       system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                       idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                       nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
    }
  }

  /// Load between two tick samples. Per core: (user + system + nice) deltas over all deltas, 0...1.
  /// Total: busy ticks over all ticks across cores. Counters wrap at 32 bits, so deltas use wrapping
  /// subtraction. Cores are paired by index; extra cores in either list are ignored. A core with no
  /// elapsed ticks reads 0.
  public static func load(prev: [CoreTicks], now: [CoreTicks]) -> (total: Double, perCore: [Double]) {
    var perCore: [Double] = []
    var busySum: UInt64 = 0, allSum: UInt64 = 0
    for (p, n) in zip(prev, now) {
      let user = UInt64(n.user &- p.user), system = UInt64(n.system &- p.system)
      let nice = UInt64(n.nice &- p.nice), idle = UInt64(n.idle &- p.idle)
      let busy = user + system + nice
      let all = busy + idle
      perCore.append(all == 0 ? 0 : Double(busy) / Double(all))
      busySum += busy; allSum += all
    }
    return (allSum == 0 ? 0 : Double(busySum) / Double(allSum), perCore)
  }
}
