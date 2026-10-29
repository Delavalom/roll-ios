import Foundation
import Testing
@testable import Entitlements
import Store

struct QuotaTests {
  let quota: FreeQuota

  init() throws { quota = FreeQuota(try AppDatabase.inMemory()) }

  @Test func limitIsFifty() { #expect(FreeQuota.limit == 50) }

  @Test func startsFull() async throws {
    #expect(try await quota.remaining() == 50)
  }

  @Test func consumingReducesRemaining() async throws {
    try await quota.consume(20)
    #expect(try await quota.remaining() == 30)
    try await quota.consume(1)
    #expect(try await quota.remaining() == 29)
  }

  @Test func fiftyAreFreeAndTheFiftyFirstThrows() async throws {
    for _ in 0..<50 { try await quota.consume(1) }
    #expect(try await quota.remaining() == 0)
    await #expect(throws: QuotaError.exceeded) { try await quota.consume(1) }
    #expect(try await quota.remaining() == 0)
  }

  @Test func overdrawingConsumesNothing() async throws {
    try await quota.consume(45)
    await #expect(throws: QuotaError.exceeded) { try await quota.consume(6) }
    #expect(try await quota.remaining() == 5)
    try await quota.consume(5)
    #expect(try await quota.remaining() == 0)
  }

  @Test func consumingZeroOrNegativeIsANoOp() async throws {
    try await quota.consume(0)
    try await quota.consume(-3)
    #expect(try await quota.remaining() == 50)
  }

  @Test func hugeRequestsDoNotOverflow() async throws {
    try await quota.consume(5)
    await #expect(throws: QuotaError.exceeded) { try await quota.consume(Int.max) }
    #expect(try await quota.remaining() == 45)
  }

  @Test func usageSurvivesReopeningTheDatabase() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-quota-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("roll.sqlite")
    try await FreeQuota(try AppDatabase.open(at: url)).consume(12)
    #expect(try await FreeQuota(try AppDatabase.open(at: url)).remaining() == 38)
  }

  @Test func sixtyParallelSpendsOnAFileBackedPoolAllowExactlyFifty() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roll-quota-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let quota = FreeQuota(try AppDatabase.open(at: dir.appendingPathComponent("roll.sqlite")))

    let successes = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<60 { group.addTask { (try? await quota.consume(1)) != nil } }
      var n = 0
      for await ok in group where ok { n += 1 }
      return n
    }
    #expect(successes == 50)
    #expect(try await quota.remaining() == 0)
  }

  // MARK: spending after a change that already happened

  @Test func consumeUpToSpendsWhatRemainsAndReportsIt() async throws {
    try await quota.consume(45)
    #expect(try await quota.consumeUpTo(8) == 5)
    #expect(try await quota.remaining() == 0)
    #expect(try await quota.consumeUpTo(3) == 0)
  }

  @Test func consumeUpToWithinTheLimitSpendsExactly() async throws {
    #expect(try await quota.consumeUpTo(7) == 7)
    #expect(try await quota.remaining() == 43)
  }

  @Test func consumeUpToIgnoresZeroNegativeAndHugeOverflow() async throws {
    #expect(try await quota.consumeUpTo(0) == 0)
    #expect(try await quota.consumeUpTo(-2) == 0)
    #expect(try await quota.consumeUpTo(Int.max) == 50)
    #expect(try await quota.remaining() == 0)
  }

  @Test func proStatusIsAnAsyncSendableProtocol() async {
    struct Fixed: ProStatus { let value: Bool; var isPro: Bool { get async { value } } }
    let status: any ProStatus = Fixed(value: true)
    #expect(await status.isPro)
  }
}
