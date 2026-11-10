# Roll: agent guide

On-device AI photo cleanup for iPhone (iOS 18+, Swift 6, SwiftUI). Requires Xcode 26+ / Swift 6.2. Spec: `docs/superpowers/specs/2026-10-22-roll-design.md`. Plan: `docs/superpowers/plans/2026-10-22-roll.md`. Milestones: `docs/MILESTONES.md`.

## Start here

1. `cp Team.xcconfig.example Team.xcconfig` and fill it in (team id, and `RC_PUBLIC_KEY`: the RevenueCat public SDK key; empty means free tier only). It is gitignored.
2. Tools come from mise (`mise.toml` pins `just` and `xcodegen`): run `mise trust && mise install`. Then call recipes as `~/.local/share/mise/shims/just <recipe>` or `mise exec -- just <recipe>`, so it works without shell activation.
3. `just gen` regenerates `Roll.xcodeproj` from `project.yml` (never committed, never hand-edited). `just build` builds for the iOS Simulator. `just test` runs the RollCore unit tests on macOS.
4. `just status` writes STATUS.md (gitignored, never edited by hand): the milestone checklist plus the last `just test` run's results (JUnit XML in `Packages/RollCore/.build`).
5. `just seed-sim` creates (or erases) the Roll-QA simulator on the newest iOS runtime and seeds it from `artifacts/seed/` (`scripts/make_seed_media.py`; needs ffmpeg and Pillow). `just uitest` runs the UI smoke test on it; re-seed after two runs (each deletes 5 screenshots).
6. CI (`.github/workflows/ci.yml`) runs only on `workflow_dispatch` while the repos are private (macOS minutes are billed); switch it to push/pull_request when they go public. Without a `GH_PAT` secret it can't check out the sibling, so `Package.swift` shrinks to Library, Signals and Monitor (also `ROLL_WITHOUT_GEMMA=1`) and the app build is skipped.

The embedding package is a sibling checkout at `../embeddinggemma-coreml/swift` (path dependency); both repos must sit side by side. To test RollCore against another checkout of it (e.g. a worktree of an unmerged branch), set `ROLL_GEMMA_PATH` to its `swift` folder (absolute, or relative to `Packages/RollCore`): `ROLL_GEMMA_PATH=/path/to/egcm-worktree/swift swift test`. Only SwiftPM reads it; the Xcode project (project.yml) always uses the sibling.

## Map

Present:

```
App/                      RollApp (registers IndexScheduler, builds AppModel), RootView (onboarding or the 3 tabs),
                          PrivacyOverlay (PrivacyShield: an opaque UIWindow at .alert + 1), Info.plist, PrivacyInfo.xcprivacy, entitlements, assets
  AppModel.swift          @Observable @MainActor composition root: database, Indexer (no embedder until the model
                          loads), loadModel → setEmbedder → SwipefileEngine, indexing lifecycle, change observer,
                          scenePhase hand-off, deck(for:) (engine or SignalDeck), committer + ReplaceFlowRunner,
                          launch squish reconcile; AppEnvironment swaps in previews
  EmbedderLoader.swift    GemmaLoader (ModelInstaller + GemmaActivator; in DEBUG, EGCM_MODEL_PATH or a bundled copy override it),
                          ModelIssue / StubLoader (DEBUG only: previews, -UITestStubEmbedder); RollApp's delegate hands
                          background-session events to BackgroundTransport
  Features/Onboarding/    one intro page, permission, TasteScanView (run(limit: 500)), then the paywall (with the scan's PaywallPitch)
  Features/Home/          HomeModel (CleanupScanner, throttled rescans on libraryRevision), cards, squish recovery banner
  Features/Swipefiles/    list, NewSwipefileView, SwipeReviewView/Model (card stack; CardImages prefetches the top 4,
                          a card with nothing on screen can only be skipped; SwipeHint explains the swipes once on an Ask
                          answer's stack, flag in defaults), CommitSheet/CommitModel
  Features/Duplicates/    groups → DuplicateGroupView; queues under __duplicates__ or __similar__ (per kind)
  Features/Squish/        SquishView/Model: SquishCatalog, toggles, "Not squishable yet"; queues under __squish__
  Features/Monitor/       MonitorModel over DeviceSampler (onAppear/onDisappear), gauges, Swift Charts history
  Shared/                 Thumbnail (ThumbnailProvider), ByteFormat, ModelStatusView, PreviewData (DEBUG),
                          UIKitBackgroundExecution, WiFi
  Entitlements.swift      @Observable @MainActor RevenueCat wrapper (the only RevenueCat import): isPro, offerings,
                          purchase, restore; conforms to ProStatus and PurchaseProvider
  Features/Paywall/       PaywallView + PaywallModel over PurchaseProvider (MockPurchaseProvider for previews)
Packages/RollCore/        Local SwiftPM package; one target per module
  Embedding/              Embedder protocol, StubEmbedder, GemmaEmbedder (.cpuAndNeuralEngine), GemmaActivator (extracted
                          folder → EmbeddingGemma.load(.installed(folder, repo:, revision:)) with the folder's own repo and
                          revision: moved into the package's store, not copied, compiled once; downloads again only when
                          the package says .downloadFailed, i.e. neither its install nor the files are there)
  ModelInstall/           PublishedModel.current (THE constant to set at publish: repo, commit, manifest sha256),
                          ModelManifest (manifest.json: one .aar + size + sha256), DownloadPolicy (Wi-Fi, not expensive,
                          not Low Data Mode, unless the person allows mobile data), InstallSpace (archive + 2x unpacked: covers
                          archive + unpacked while extracting and unpacked + compiled while the package compiles),
                          AppleArchiveExtractor, ModelInstaller (actor: <rev>.partial → <rev>/ = .roll-model.json + model/;
                          the activator gets model/ and the marker's ModelIdentity, and only the marker stays; old
                          revision in use until the new one is staged, then deleted), BackgroundTransport (background URLSessions, resumable; its bookkeeping
                          is TransportBook, tested without a network)
  Store/                  GRDB schema (v1-v10; v10: assetText + FTS5 keyword index, Repositories.keywordCoverage), records, Repositories, VectorStore (actor over EmbeddingIndex),
                          squishJournal, squishRefusal (remembered run-time refusals; hold while asset.modified is unchanged)
  Entitlements/           FreeQuota (policy only; the counter is Repositories.consumeCounter), ProStatus protocol
  Commit/                 CommitPlanner (pure; `protecting:` keeps one shot of a duplicate group), PhotoKitCommitter
                          (deletes in chunks of 500, albums, squishes via the SquishRunner seam; records with
                          recordApplied, then spends quota; retrySquishDeletes enforces the free quota itself),
                          SquishRunner protocol
  Dedupe/                 DuplicateGrouper (no chaining: bursts, then exact-hash copies, then moments: each member within 60 s and print distance < 0.30 of the group's first shot, up to 64 checked; injected print distance), KeeperPolicy
  Squish/                 SquishCandidates + SquishPlanner (spec §8 rules, 30% savings floor; depends on Store only), SquishEligibility (typed refusals incl. formats), VideoSquisher (HEVC export), PhotoSquisher (HEIC 0.8, keeps gain map + metadata), ReplaceFlow (needs full access; prepare copies, journaled in Store, then one commitDeletes that re-verifies inside the change block; PhotoKit behind an internal seam, iOS only)
  Ranking/                Preset (filters, boosts, prompts), Scorer, LogisticClassifier (vDSP), SwipefileEngine (actor: in-memory candidate rows (CandidatePool, refreshed after ranking-relevant writes) + one VectorStore.dotAll matrix product, aligned as integers (PoolScores); untrained piles on each query's own scale (QueryScale, z >= 2) with weaker matches folded (Fold, 0.4); rank-based once trained, class-balanced retraining, isLikelyExhausted); SwipeDeck protocol + SignalDeck (Screenshots/Blurry/Big videos without the model); LibrarySearch (typed queries: z + keyword coverage, DigUp-style), SearchTerms
  Overview/               CleanupSummary/CleanupScanner (Home categories, duplicate groups minus keepers, freeable total:
                          deletions at full size + big videos at SquishPlanner.offer savings; journaled copies and
                          open squishes excluded; groups() reads feature prints, scan(groups:) the slim rows),
                          DuplicateReview (queues __duplicates__ / __similar__), SystemSwipefile (hidden "__" swipefiles),
                          PaywallPitch (the paywall's "Free about X on this iPhone" from the on-device headline, 100 MB floor)
  SquishBridge/           ReplaceFlowRunner (ReplaceFlow as Commit's SquishRunner; PreparedRegistry; reconcile),
                          SquishRefusal (UI text), SquishCatalog (skips remembered refusals), SquishQueue (__squish__)
                          CandidateChecks (after indexing drains: LocalityScanner, then SquishFormatScreen; timeouts,
                          one round at a time, each item checked at most once an hour)
  Monitor/                HostStats (Mach memory + CPU ticks, pure load()), StorageStats, DeviceSampler (@Observable, 1 Hz, 60-sample ring); read-only, no performance claims
  Library/                SizeEstimator, AssetSnapshot, thumbnails/frames (ThumbnailResult), change observer; PhotoKit parts are iOS-only;
                          CardImage (ImageRequestSpec, CardImageLoader: best local image, else a download on Wi-Fi only,
                          else "unavailable", 8 s lookup timeout; CardGate; CardPrefetch), SwipeVerdict (gate → record, skip
                          or ignore: only a card on screen records), SharedWiFiCheck + NetworkPath (Low Data Mode allowed)
  Signals/                Vision signals: blur, aesthetics, feature print (FP01 raw floats), dHash, sensitive content; AssetSignals; TextRecognizer (.accurate at 960 px, no language correction)
  Indexer/                TextIndexer (words of gated images: screenshots + isUtility, after indexing drains, pauses from thermal .fair); Indexer actor (sync/apply, run(limit:allowNetwork:), flush, cancel, setEmbedder(_:openVectors:), AsyncStream progress) over LibrarySource/SignalSource/
                          IndexRepository/VectorSink protocols; ThermalGate; IndexScheduler (BGProcessingTask, iOS)
UITests/                  SmokeTests: launch, and the seeded flow (onboarding → taste scan → Screenshots → swipe 5 →
                          apply → system delete alert → count drops by 5); PaywallTests: both plans, prices, trial,
                          links (needs RC_PUBLIC_KEY + network); OnboardingPitchTests: the paywall after the taste scan repeats its number. DEBUG launch args -UITestStubEmbedder,
                          -UITestSkipPaywall, -UITestResetState (keeps the squish journal while a squish is open),
                          -UITestOpen paywall|squish, -UITestTab. DeviceQATests: device QA (docs/qa/); -QAAlbum runs
                          use their own database under Application Support/qa
Roll.storekit             Local StoreKit config (Roll Pro group 22506661: roll_pro_annual $29.99 + 3-day trial,
                          roll_pro_weekly $4.99). The Run action of the Roll scheme only (project.yml), so it applies
                          when Xcode runs the app (Cmd-R); simctl launches, `xcodebuild test`, Release and archives
                          use the App Store. Keep it in step with App Store Connect.
scripts/                  seed_sim.sh + make_seed_media.py (Roll-QA), gen_status.py (STATUS.md), device_udid.py,
                          make_test_fixtures.py, qa_restock.sh + make_qa_restock_media.py (device QA album restock,
                          -QARestock), check_release_no_qa.sh (`just release-check`: no DEBUG QA code in
                          Release; run before TestFlight), eval/ (pile-eval: evals/piles.json, proxy-labelled queries,
                          against a private copy of a library's Store + index; docs/investigations/2026-10-29-pile-eval.md)
.github/workflows/ci.yml  manual-only CI (see Start here)
docs/                     MILESTONES.md, decisions/ (ADRs), superpowers/ (spec, plan), legal/ (privacy policy and terms:
                          the source of truth for the site)
site/                     https://roll.delavalom.com (Vercel project roll-site): `python3 site/build.py` renders
                          docs/legal/*.md + src/pages into public/ (committed, served as is; values in site.json)
```

## Rules

- Core logic goes in RollCore with tests, never in views. TDD: failing test first (Swift Testing).
- Every destructive PhotoKit call lives only in `Commit/PhotoKitCommitter.swift` or `Squish/ReplaceFlow.swift`.
- No network except the model download (`ModelInstall`'s `BackgroundTransport`, Hugging Face) and RevenueCat. No analytics SDKs.
- Copy rule (ADR-0002): never "boost", "free RAM", "speed up" or any performance claim. Sizes are always "about".
- **`StubEmbedder` is for tests and previews only.** If the real model fails to load, the result is "search unavailable" (signals-only indexing continues). Never fall back to the stub in a shipping path, because stub vectors in the real index are garbage. Switching embedder revisions wipes the index (`VectorStore` resets it, clears `asset.embedded` and drops every swipefile classifier in the same transaction).
- `VectorIndex` is not Sendable: it lives privately inside the `VectorStore` actor.
- **Commit order for embeddings:** `vectors.upsert` (batch) → `vectors.save()` → `repo.markEmbedded(ids:)`. Never flag an asset embedded before the vector file holding it is saved. `VectorStore.reconcile()` (also run on open) clears any flag without a vector.
- Each writer touches only its own columns: Vision signals via `Repositories.commitSignals` (never touches `embedded`), the embedded flag via `markEmbedded` / `clearEmbedded`, library metadata via `upsertAssets`. Re-embedding after a model change therefore never erases signals. `replaceAssetsForTesting` is for test fixtures.
- Quota is spent after the change succeeds (ADR-0003): `PhotoKitCommitter` records each successful change with `Repositories.recordApplied`, then calls `FreeQuota.consumeUpTo`. A declined system prompt costs nothing.
- RevenueCat stays in the app target (`App/Entitlements.swift`). RollCore asks `ProStatus`. The SDK key comes from `RC_PUBLIC_KEY` in Team.xcconfig via the Info.plist key `RCPublicKey`; never commit or print it. DEBUG builds launched with `-RCTestStore` use the RevenueCat Test Store key instead (`RC_TEST_STORE_KEY` → `RCTestStoreKey`; project.yml forces it empty for Release, so release and archive builds never contain it). The Test Store has no free trials.
- **Indexer wiring (Task 13).** `RollApp.init` calls `IndexScheduler.register(indexer:)` (BackgroundTasks needs it before launch finishes). Build the `Indexer` with `embedder: nil` until `GemmaEmbedder.load` succeeds, then call `setEmbedder(_:openVectors:)`; the closure opens `VectorStore` for the given revision and dimensions. The Indexer stops the active run, drains its writes, opens the store and starts the embed-only catch-up, in that order. Callers of the stopped run are carried over; a limited caller (the taste scan's `run(limit: 500)`) gets its limited run back first and the catch-up follows it. Don't open the store yourself first: a new revision wipes the file. On `scenePhase == .background` call `IndexScheduler.appDidEnterBackground(indexer:)` (flush, stop, schedule). Feed `ChangeObserver` changes to `indexer.apply(_:)`, then `run()`. `sync()`/`apply()` run one at a time; concurrent `run()` calls share a run (the taste scan uses `run(limit: 500)`). Ranking and search must filter `deleted = 0`. Vectors of deleted or edited assets are purged through the attached store; pass `vectors:` without `embedder:` to purge through a store already open at the last revision while the model loads. With no store at all, `VectorStore.reconcile()` on the next open removes every vector that no live, flagged row claims. `Repositories.resetFailures()` retries assets whose loads failed 3 times.
