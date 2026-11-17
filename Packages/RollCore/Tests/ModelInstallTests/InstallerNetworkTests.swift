import Foundation
import Testing
@testable import ModelInstall

/// The installer and the network: Wi-Fi only by default, Low Data Mode, mobile data when the person allows it.
struct InstallerNetworkTests: InstallerTesting {
  @Test func offWiFiItSaysSoAndKeepsTheDownloadWiFiOnly() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    _ = try await sut.load(activator: FakeActivator(), report: steps.report)

    #expect(steps.all.first == .waiting(.wifi, totalBytes: nil))
    #expect(steps.all.contains { if case .waiting(.wifi, let total?) = $0 { total > 0 } else { false } })
    #expect(transport.calls.allSatisfy { !$0.allowCellular })
  }

  @Test func offWiFiTheLastStepBeforeTheTransferIsWaiting() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    transport.hang(archiveName)  // the background session holding the download until Wi-Fi
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    let waiting = Task { try await sut.prepare(allowCellular: false, report: steps.report) }
    while transport.calls(for: archiveName).isEmpty { try await Task.sleep(for: .milliseconds(5)) }

    guard case .waiting(.wifi, let total?) = steps.all.last else {
      Issue.record("expected waiting for Wi-Fi with the size, got \(steps.all)")
      return
    }
    #expect(total > 0)
    #expect(!steps.all.contains { if case .downloading = $0 { true } else { false } })
    waiting.cancel()
    _ = try? await waiting.value
  }

  @Test func offWiFiDownloadingIsReportedOnlyOnceBytesArrive() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    _ = try await sut.prepare(allowCellular: false, report: steps.report)

    #expect(!steps.all.contains(where: { if case .downloading(0, _) = $0 { true } else { false } }))
    let first = try #require(steps.all.firstIndex { if case .downloading = $0 { true } else { false } })
    #expect(first > 0)
    guard case .waiting(.wifi, _?) = steps.all[first - 1] else {
      Issue.record("expected waiting right before the first bytes, got \(steps.all)")
      return
    }
  }

  @Test func onWiFiDownloadingIsReportedAtOnce() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    transport.hang(archiveName)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport)

    let running = Task { try await sut.prepare(allowCellular: false, report: steps.report) }
    while transport.calls(for: archiveName).isEmpty { try await Task.sleep(for: .milliseconds(5)) }

    guard case .downloading(0, let total) = steps.all.last else {
      Issue.record("expected downloading from zero, got \(steps.all)")
      return
    }
    #expect(total > 0)
    running.cancel()
    _ = try? await running.value
  }

  @Test func lowDataModeOnWiFiWaitsLikeCellular() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    var lowData = NetworkPath.wifi
    lowData.isConstrained = true
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(lowData))

    _ = try await sut.load(activator: FakeActivator(), report: steps.report)

    #expect(steps.all.first == .waiting(.lowDataMode, totalBytes: nil))
    #expect(transport.calls.allSatisfy { !$0.allowCellular })
  }

  @Test func mobileDataWhenThePersonAllowsIt() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    let steps = Steps()
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    _ = try await sut.load(allowCellular: true, activator: FakeActivator(), report: steps.report)

    #expect(!steps.all.contains { if case .waiting = $0 { true } else { false } })
    #expect(transport.calls.allSatisfy { $0.allowCellular })
  }

  @Test func allowingMobileDataRestartsAWiFiOnlyDownload() async throws {
    let dir = TempDir()
    defer { dir.cleanUp() }
    let transport = try publish(in: dir)
    transport.hang(archiveName)
    let sut = installer(root: root(dir), transport: transport, conditions: .fixed(.cellular))

    let waiting = Task { try await sut.prepare(allowCellular: false) { _ in } }
    while transport.calls(for: archiveName).isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    transport.hang(archiveName, false)
    let folder = try await sut.prepare(allowCellular: true) { _ in }

    #expect(await sut.localState() == .staged(folder))
    #expect(transport.calls(for: archiveName).map(\.allowCellular) == [false, true])
    await #expect(throws: CancellationError.self) { try await waiting.value }
  }
}
