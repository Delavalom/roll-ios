import Foundation
import Indexer
import Monitor
import Store

/// The work around indexing that runs outside its loop: the opt-in iCloud upgrade, the locality and format checks.
/// Moved out of AppModel.swift unchanged (that file's size limit).
extension AppModel {
  /// The opt-in iCloud upgrade (it downloads full images): watched for its whole run, so it runs only while it's on,
  /// preview rows are left, and the iPhone is on Wi-Fi (not expensive or constrained) and charging. When a condition
  /// fails the Indexer is cancelled and local indexing resumes without the network.
  func refreshUpgrade() {
    guard environment.isLive else { return }
    if upgradeMonitor == nil {
      let indexer = indexer, text = textIndexer
      let supervisor = ICloudUpgradeSupervisor(
        run: { [weak self] in
          #if DEBUG
          QARuntime.shared?.log.write("upgrade_pass", ["state": .string("started")])
          #endif
          // Words only after a finished upgrade: a cancelled one (backgrounded, Wi-Fi or charging lost) must not
          // start a network text pass.
          if (try? await indexer.run(allowNetwork: true, upgradePreviews: true)) != nil {
            _ = try? await text.run(allowNetwork: true)
          }
          await MainActor.run {
            guard let self else { return }
            Task { self.previewCount = (try? await self.repositories.previewAssetCount()) ?? self.previewCount }
            self.bumpLibrary()
          }
        },
        cancel: { [weak self] in
          #if DEBUG
          QARuntime.shared?.log.write("upgrade_pass", ["state": .string("cancelled: Wi-Fi or charging stopped")])
          #endif
          await indexer.cancel()
          await text.cancel()
          await MainActor.run { self?.startIndexing() }  // local work goes on without the network
        })
      upgradeMonitor = ICloudUpgradeMonitor(supervisor: supervisor)
    }
    upgradeMonitor?.refresh(enabled: improveWithICloud, pending: previewCount > 0)
  }

  /// After indexing has drained: checks where the originals of cleanup candidates are (Home's latest candidates, so
  /// its duplicate groups are reused, plus Squish's; not-yet-checked first, largest first, each at most once an hour),
  /// then local big videos' formats, at utility priority with network off. Unknown counts as iCloud until then. Runs
  /// outside `indexTask`; a call during a round makes one more round after it (`CandidateChecks`).
  func startChecks() {
    guard environment.isLive, access.canRead else { return }
    let checks = checks, candidates = home.hasLoaded ? home.summary.localityCandidates : nil
    Task.detached(priority: .utility) { [weak self] in
      guard let outcome = await checks.run(homeCandidates: candidates) else { return }  // folded into a running round
      #if DEBUG
      let ms = Int(outcome.elapsed.components.seconds * 1000
                   + outcome.elapsed.components.attoseconds / 1_000_000_000_000_000)
      QARuntime.shared?.log.write("locality_scan", [
        "candidates": .int(outcome.candidates), "checked": .int(outcome.locality.checked),
        "local": .int(outcome.locality.local), "iCloud": .int(outcome.locality.iCloud),
        "unanswered": .int(outcome.locality.unanswered), "timedOut": .int(outcome.locality.timedOut),
        "formats": .int(outcome.formats.recorded), "rounds": .int(outcome.rounds), "ms": .int(ms),
      ])
      #endif
      if outcome.changed { await self?.bumpLibrary() }
    }
  }

  /// Probes local big videos' formats so Squish and Home's savings leave Dolby Vision (and ProRes/Log) out.
  func screenSquishFormats() async {
    guard environment.isLive, access == .full || access == .limited else { return }
    // Passes change Home's squish savings too, so refresh either way (Home rescans are throttled).
    if (try? await squishScreen.run()) != nil { bumpLibrary() }
  }
}
