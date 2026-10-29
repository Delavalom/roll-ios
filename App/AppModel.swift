import Commit
import Embedding
import EmbeddingGemma
import Entitlements
import Foundation
import Indexer
import Library
import ModelInstall
import Monitor
import Observation
import Overview
import Ranking
import Signals
import Squish
import SquishBridge
import Store
import SwiftUI
import Synchronization
import os

/// The app's composition root: database, Indexer, the embedder and its vector store, the swipefile engine,
/// entitlements and the device sampler. Owns the onboarding flag and the app-wide indexing lifecycle.
///
/// The Indexer starts without an embedder ("search unavailable", signals only). `loadModel()` loads the model and
/// attaches it with `Indexer.setEmbedder(_:openVectors:)`, which opens the `VectorStore` itself (AGENTS.md). If the
/// model can't load, `modelState` is `.unavailable` and the UI offers a retry; nothing else waits on it. The download
/// waits for Wi-Fi without Low Data Mode unless the person chooses mobile data (`downloadModelAnyway`).
@Observable @MainActor
final class AppModel {
  enum ModelState: Equatable {
    /// Downloading (with progress), unpacking or loading.
    case loading(ModelProgress?)
    /// First launch after an install or an update: the model's parts compile for the Neural Engine, one at a time
    /// (minutes each), before search and indexing start (`prepareIfNeeded`).
    case preparing(done: Int, total: Int)
    /// Queued until the network allows the download (`DownloadPolicy`); it starts by itself. The size once known.
    case waiting(NetworkWait, totalBytes: Int64?)
    case ready
    case unavailable(ModelIssue)
  }

  static let onboardingKey = "onboardingComplete"
  /// The model revision, app build and data container whose functions were last prepared (`prepareIfNeeded`,
  /// `SearchPreparation.marker`).
  static let searchPreparedKey = "searchPreparedFor"
  /// Opt-in: re-analyse preview rows from iCloud originals, on Wi-Fi while charging. Off by default.
  static let improveWithICloudKey = "improveWithICloudOriginals"

  let database: AppDatabase
  let repositories: Repositories
  let indexer: Indexer
  /// Words in screenshots and documents (`TextIndexer`): runs after indexing drains (AppModel+Text.swift).
  let textIndexer: TextIndexer
  let entitlements: Entitlements
  let sampler: DeviceSampler
  let home: HomeModel
  let thumbnails: any ThumbnailProvider
  let skipsPaywall: Bool
  /// Verified squish copies, shared by every runner so a copy prepared (or reconciled) by one commits through another.
  let squishRegistry = PreparedRegistry()

  /// Set by the model extension (AppModel+Model.swift) only.
  internal(set) var modelState: ModelState = .unavailable(.notStarted)
  /// Preparing stopped because the iPhone is low on storage: search works, but each part of the model compiles on
  /// first use (slower), and iOS may delete compiled parts to make room. Home says so.
  internal(set) var searchStorageLow = false
  /// Present once the model is attached; previews and `-UITestStubEmbedder` attach `StubEmbedder`.
  internal(set) var engine: SwipefileEngine?
  private(set) var access: AccessState
  private(set) var indexProgress = IndexProgress(runId: 0, processed: 0, total: 0, phase: .idle)
  private(set) var onboardingComplete: Bool
  /// Interrupted squishes found on launch (Home shows a banner while it's not empty).
  internal(set) var squishRecovery = SquishRecovery()
  /// Pending copies the last "Finish" couldn't replace because the free quota ran out (Home offers Pro or removal).
  internal(set) var squishRecoveryBlockedByQuota = 0
  /// Squishes left open in the journal while access is limited (reconcile needs full access): Home asks for it.
  internal(set) var openSquishesNeedingFullAccess = 0
  var squishMessage: String?
  /// Bumped when the Store's view of the library changed: an index batch landed, a sync or a commit finished.
  private(set) var libraryRevision = 0
  /// Assets analysed from a small local preview because their originals are in iCloud.
  private(set) var previewCount = 0
  /// "Improve with iCloud originals" (Home): when on, preview rows are re-analysed from full images downloaded from
  /// iCloud, only on Wi-Fi while the iPhone charges.
  var improveWithICloud: Bool {
    didSet {
      environment.defaults.set(improveWithICloud, forKey: Self.improveWithICloudKey)
      refreshUpgrade()
    }
  }
  /// Reads local videos' formats before Squish offers them (Dolby Vision is kept as is).
  let squishScreen: SquishFormatScreen
  /// Locality and format checks after indexing (`startChecks`), kept for the launch.
  let checks: CandidateChecks
  /// Runs the opt-in iCloud upgrade only while Wi-Fi and charging hold (live builds).
  @ObservationIgnored private var upgradeMonitor: ICloudUpgradeMonitor?

  @ObservationIgnored let environment: AppEnvironment
  @ObservationIgnored var modelTask: Task<Void, Never>?
  /// Bumped per `loadModel`, so a superseded attempt (cancelled for mobile data) can't report or fail the new one.
  @ObservationIgnored var modelAttempt = 0
  @ObservationIgnored private var indexTask: Task<Void, Never>?
  @ObservationIgnored private var indexAgain = false
  /// Bumped when a new indexing loop starts or the app goes to the background: a text pass queued by an earlier
  /// drain (`afterIndexDrained`) checks it and doesn't start.
  @ObservationIgnored private(set) var textGeneration = 0
  @ObservationIgnored private var progressTask: Task<Void, Never>?
  @ObservationIgnored private var observerTask: Task<Void, Never>?
  @ObservationIgnored private var lastBatch = (runId: -1, batch: -1)
  /// When the last full library sync finished. A full read of a 30k library is the hottest part of a launch (device
  /// QA: thermal `serious` within 48 s), so a sync is skipped when one finished within `syncReuse`; changes since then
  /// arrive through the change observer (`apply`) anyway.
  @ObservationIgnored private var lastFullSync: ContinuousClock.Instant?
  static let syncReuse: Duration = .seconds(600)
  /// File types looked up per indexing round (`Indexer.resolveTypes`).
  static let typeLookupBatch = 1_000

  init(environment: AppEnvironment) throws {
    self.environment = environment
    database = environment.database
    repositories = Repositories(environment.database)
    squishScreen = SquishFormatScreen(probe: PhotoKitVideoFormatProbe(), repositories: repositories)
    checks = CandidateChecks(repositories: repositories,
                             locality: LocalityScanner(repositories: repositories, checker: PhotoKitLocality()),
                             formats: squishScreen)
    indexer = try Indexer(library: environment.library, signals: SignalExtractor(), repo: repositories)
    textIndexer = TextIndexer(library: environment.library, reader: TextRecognizer(), repo: repositories)
    entitlements = Entitlements()
    sampler = DeviceSampler()
    home = HomeModel(repositories: repositories)
    thumbnails = environment.thumbnails
    skipsPaywall = environment.skipsPaywall
    access = environment.access.current()
    onboardingComplete = environment.defaults.bool(forKey: Self.onboardingKey)
    improveWithICloud = environment.defaults.bool(forKey: Self.improveWithICloudKey)
  }

  /// The production app. DEBUG builds only (the UI smoke test, Task 14): `-UITestStubEmbedder` attaches
  /// `StubEmbedder`, `-UITestSkipPaywall` skips the onboarding paywall, and `-UITestResetState` starts over (Roll's
  /// database, vector index and onboarding flag are removed before anything opens them; an unfinished squish's journal
  /// is kept). Release builds ignore them.
  static func live() throws -> AppModel {
    var loader: any EmbedderLoader = GemmaLoader.live()
    var skipsPaywall = false
    var library: any LibrarySource = PhotoLibrary()
    var supportDirectory: URL?
    var defaults = UserDefaults.standard
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-UITestStubEmbedder") { loader = StubLoader() }
    skipsPaywall = arguments.contains("-UITestSkipPaywall")
    // Device QA (App/QA): `-QAAlbum` scopes the library to one album and keeps its own database, vector index and
    // onboarding flag under Application Support/qa; `-QAMetrics` records identifier-free metrics.
    if let qa = QARuntime.shared {
      library = qa.library
      supportDirectory = qa.storageBase
      if let qaDefaults = qa.defaults { defaults = qaDefaults }
    }
    if arguments.contains("-UITestResetState") {
      try resetStateForUITests(database: try AppDatabase.defaultURL(in: supportDirectory), defaults: defaults)
    }
    #endif
    let environment = AppEnvironment(
      database: try AppDatabase.open(at: try AppDatabase.defaultURL(in: supportDirectory)),
      supportDirectory: supportDirectory, library: library, access: PhotoKitAccess(), loader: loader,
      thumbnails: PhotoThumbnails(), defaults: defaults, isLive: true, skipsPaywall: skipsPaywall)
    return try AppModel(environment: environment)
  }

  #if DEBUG
  /// `-UITestResetState`: a fresh install's state, without reinstalling, except that an unfinished squish survives
  /// (`AppDatabase.resetForUITests`): its journal is kept so the recovery banner and the copy exclusions still work.
  private static func resetStateForUITests(database url: URL, defaults: UserDefaults) throws {
    switch try AppDatabase.resetForUITests(at: url) {
    case .removedEverything:
      break
    case .keptSquishJournal(let open):
      QARuntime.logger.notice("-UITestResetState kept the squish journal: \(open) unfinished squishes")
      QARuntime.shared?.log.write("ui_test_reset", ["keptSquishJournal": .bool(true), "openSquishes": .int(open)])
    }
    defaults.removeObject(forKey: onboardingKey)
  }
  #endif

  /// Called once at launch.
  func start() {
    if environment.isLive { entitlements.configure(apiKey: Entitlements.apiKeyFromInfoPlist()) }
    observeProgress()
    Task { try? await ensurePresetSwipefiles() }
    if onboardingComplete || access.canRead { loadModel() }
    if onboardingComplete { bumpLibrary() }
    if onboardingComplete && access.canRead {
      startIndexing()
      observeLibrary()
    }
    Task { await reconcileSquishes() }
  }

  // MARK: - Photos access

  func requestAccess() async {
    access = await environment.access.request()
    if access.canRead {
      loadModel()
      observeLibrary()
      await reconcileSquishes()
    }
  }

  // MARK: - Onboarding

  func completeOnboarding() {
    onboardingComplete = true
    environment.defaults.set(true, forKey: Self.onboardingKey)
    bumpLibrary()
    if access.canRead { startIndexing() }
  }

  /// The taste scan (spec §10 step 3): syncs the library, then indexes the newest 500 assets.
  func runTasteScan() async throws {
    await textIndexer.cancel()
    try await indexer.sync()
    lastFullSync = .now
    bumpLibrary()
    _ = try await indexer.run(limit: 500)
    bumpLibrary()
  }

  // MARK: - Indexing

  /// Syncs the library and indexes everything pending. A call while indexing is running makes it go round once
  /// more when it finishes (concurrent `run()` calls share one run anyway). Once the loop has drained (file types
  /// included), the locality and format checks run outside it (`startChecks`).
  func startIndexing() {
    guard environment.isLive, access.canRead else { return }
    if indexTask != nil {
      indexAgain = true
      return
    }
    textGeneration += 1
    indexTask = Task { [weak self] in
      await self?.textIndexer.cancel()  // the photo pass goes first; the text pass resumes once it drains
      var drained = false
      repeat {
        guard let self else { return }
        self.indexAgain = false
        drained = false
        do {
          if self.lastFullSync.map({ ContinuousClock.now - $0 < Self.syncReuse }) != true {
            _ = try await self.indexer.sync()
            self.lastFullSync = .now
            self.bumpLibrary()
          }
          _ = try await self.indexer.run()
          // File types only for the photos that need one (Squish and size candidates), lazily, in batches until none
          // is left. Batches don't go round the loop: that started an empty index run per batch, and a full library
          // sync once the last one was over `syncReuse` old (the 30k proof: 11 batches, 11 empty runs, one 39 s sync).
          while !Task.isCancelled,
                let resolved = try? await self.indexer.resolveTypes(limit: Self.typeLookupBatch), resolved > 0 {
            #if DEBUG
            QARuntime.shared?.log.write("types_resolved", ["count": .int(resolved)])
            #endif
            self.bumpLibrary()
            if resolved < Self.typeLookupBatch { break }
          }
          self.previewCount = (try? await self.repositories.previewAssetCount()) ?? self.previewCount
          self.refreshUpgrade()
          drained = true
        } catch {
          // Cancelled (backgrounded) or failed: the Indexer flushed what it finished; the next activation resumes.
        }
      } while self?.indexAgain == true && !Task.isCancelled
      guard let self else { return }
      self.indexTask = nil
      self.bumpLibrary()  // Home held off regrouping while the loop ran
      if drained {
        self.startChecks()
        self.afterIndexDrained()
      }
    }
  }

  /// The opt-in iCloud upgrade (it downloads full images): watched for its whole run, so it runs only while it's on,
  /// preview rows are left, and the iPhone is on Wi-Fi (not expensive or constrained) and charging. When a condition
  /// fails the Indexer is cancelled and local indexing resumes without the network.
  private func refreshUpgrade() {
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
  private func startChecks() {
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

  /// Follows the Indexer's progress, and bumps `libraryRevision` after each 200-asset batch and each finished run
  /// (that's when the Store has new signals to show).
  private func observeProgress() {
    let indexer = indexer
    progressTask = Task { [weak self] in
      for await progress in await indexer.progressUpdates() {
        guard let self else { return }
        self.indexProgress = progress
        switch progress.phase {
        case .indexing:
          let batch = progress.processed / 200
          if batch > 0, (progress.runId, batch) != self.lastBatch {
            self.lastBatch = (progress.runId, batch)
            self.bumpLibrary()
          }
        case .finished, .cancelled, .failed:
          self.bumpLibrary()
        default:
          break
        }
      }
    }
  }

  /// Feeds Photos changes to the Indexer, then indexes what's new.
  private func observeLibrary() {
    guard environment.isLive, observerTask == nil else { return }
    let indexer = indexer
    observerTask = Task { [weak self] in
      let observer = ChangeObserver()
      observer.start()
      for await change in observer.changes {
        _ = try? await indexer.apply(change)
        guard let self else { return }
        self.bumpLibrary()
        if self.onboardingComplete { self.startIndexing() }
      }
    }
  }

  func scenePhaseChanged(_ phase: ScenePhase) {
    guard environment.isLive else { return }
    switch phase {
    case .background:
      textGeneration += 1
      let indexer = indexer, text = textIndexer
      Task { await IndexScheduler.appDidEnterBackground(indexer: indexer, text: text) }
    case .active:
      let previous = access
      access = environment.access.current()
      if access != previous { accessChanged(from: previous) }
      if onboardingComplete { startIndexing() }
    default:
      break
    }
  }

  /// Access changed in Settings while Roll was away: start what the new level allows.
  private func accessChanged(from previous: AccessState) {
    lastFullSync = nil  // a different set of assets is visible now: the next start reads the library again
    if access.canRead, !previous.canRead {
      loadModel()
      observeLibrary()
    }
    if access == .full || previous == .full { Task { await reconcileSquishes() } }
    bumpLibrary()
  }

  /// Something changed what the Store says about the library (also called after a commit).
  func bumpLibrary() {
    libraryRevision &+= 1
    let running: [IndexProgress.Phase] = [.syncing, .started, .indexing, .thermalPause]
    // The indexing loop's type-lookup rounds don't change groups: Home regroups when the loop ends.
    if onboardingComplete { home.libraryChanged(indexing: indexTask != nil || running.contains(indexProgress.phase)) }
  }
}
