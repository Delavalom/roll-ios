# Durable on-device AI setup: design

**Date:** 2026-11-16
**Status:** approved by the founder in conversation (every decision below was their answer). Separate spec review waived
("go ahead and work on everything").

## Problem

A new user's on-device AI takes four slow steps: the model download (343 MB, minutes), install (unpack and compile,
about a minute), prepare (each of 9 functions compiled for the Neural Engine, 45–230 s each, 7–30 min in all) and the
library read (30k photos: about 27 min unpaused, 76 min with thermal pauses). Only the download continues when Roll
leaves the screen. Install and prepare stop; the library read continues only overnight while charging, and only if the
model already loaded in the foreground. Every app update makes prepare run again (the Neural Engine cache key holds the
model's path, which moves with the data container). Nothing calls the user back when they leave mid-way.

Goals, in the founder's order: setup finishes reliably and completely without babysitting (critical); the wait feels
good and gives a reason to come back (critical). Early partial search is not a goal: cleanup already works without the
model.

## Decisions

| Question | Decision |
|---|---|
| How setup begins | One clear moment: a "Set up on-device AI" screen at the end of onboarding (and from Home), one tap |
| Where the task ends | At the whole library read: one task, two stages ("Getting the AI ready", "Reading photos") |
| After an app update | Home row "Roll was updated: finish setting up the AI", same one-tap task; overnight job as fallback |
| Avoid the post-update compile | Experiment: keep the model in an App Group container (its path and inodes don't move on update) |
| While waiting, in Roll | The setup screen right after the tap (screen kept awake while it shows and runs), then a Home card with an invitation to the free cleanup |
| iOS 18–25 | Same screens; work continues while Roll is open and overnight while charging |
| Notification | Opt-in button on the setup screen ("Tell me when it's ready") |
| Architecture | One coordinator, several runners |

## Architecture

### `Setup` (RollCore module): `SetupCoordinator`

An actor that owns the sequence and nothing else. The app supplies the work through a protocol:

```swift
public protocol SetupWork: Sendable {
  /// Downloads, installs, prepares and attaches the model; returns when it is attached.
  func readyModel(report: @escaping @Sendable (ModelStep) -> Void) async throws
  /// Photos read so far (signals and embeddings) and in all, from the Store.
  func libraryCounts() async -> LibraryCounts
  /// Reads the library until nothing is pending or the task is cancelled.
  func readLibrary(report: @escaping @Sendable (LibraryCounts) -> Void) async throws
}
```

- **Derived, not stored.** Each run asks the world where it stands: the model step (`readyModel` is quick when the
  model is attached; the installer and the prepare marker skip what's done) and the library counts. After an app
  update, a cache purge, a crash or a killed task, the next run does only what's missing.
- **Leases.** Each runner holds a lease (`acquire(_ holder:)` → token, `release(token)`). The first lease starts a run;
  later leases join it; the run is cancelled when the last lease is released. So the app coming to the front while the
  overnight job runs keeps the same run going, and the app leaving the front doesn't stop a run the continued task
  still holds.
- **Progress.** `SetupProgress`: the stage (`.model(ModelStep)`, `.library(LibraryCounts)`, `.done`), and one
  overall fraction for iOS's progress (model 0–0.35: download 0–0.15, install 0.15–0.2, prepare 0.2–0.35; library
  0.35–1 by photos read). While a function compiles, prepare's share creeps on a time estimate (120 s per function,
  never past the next function's start), so iOS never sees a stalled task.
- **Outcome.** `.finished`, `.stopped` (lease released, expired, cancelled) or `.blocked(SetupBlock)`: waiting for
  Wi-Fi, not enough space, no Photos access, or failed (with the error's description).

### Runners (app)

1. **Foreground:** `AppModel` holds a lease while the scene is active and onboarding is done (as today, setup advances
   whenever Roll is open). Replaces the separate `loadModel` → `prepareIfNeeded` → `startIndexing` start.
2. **Continued (iOS 26+):** the "Set up" tap submits a `BGContinuedProcessingTaskRequest`
   (`com.delavalom.roll.setup.run`, Info.plist `com.delavalom.roll.setup.*`, strategy `.queue`). Its handler holds a
   lease, forwards progress to `task.progress` and `updateTitle(_:subtitle:)`, and completes when the run ends.
3. **Overnight:** the existing charging-only `BGProcessingTask` (`com.delavalom.roll.index`) readies the model first
   (`IndexScheduler.perform(setUp:)`), then indexes and reads words as today.

On `scenePhase == .background`, the foreground lease is released; the Indexer's background flush-and-stop runs only
when no other lease holds the run.

### UI

- **Setup screen** (`SetupView`): what the AI unlocks, the two stages with counts and bars, roughly how long, "best on
  Wi-Fi and plugged in", "Tell me when it's ready", "Continue". The idle timer is off while it is visible and a run is
  going. Shown as the last onboarding step (after the paywall) and from Home.
- **Home card** (`SetupCard`), replacing the model notice while setup isn't finished: the stage and progress, the
  cleanup invitation ("Clear 2,572 screenshots while you wait"), and the action: "Set up" (never started), "Finish
  setting up" (after an update or a purge), or the existing Wi-Fi / space / retry choices when blocked.
- **Notifier:** posts "Roll has read your N photos" once, when a run returns `.finished` while Roll isn't in front and
  the person opted in.

### App Group experiment

The model's two folders (Roll's install root and the package's store) live in the App Group container
`group.com.delavalom.roll` when it is available, moved there once from the data container (a rename on the same
volume; the move costs one cold compile, never a download). If the container's path survives a TestFlight update,
prepare after an update loads warm (about 3.5 s per function instead of 45–230 s). Measured with two TestFlight builds
installed one after the other; kept only if it works. Low-storage purges still need the Home row.

## Error handling

- Download waits (Wi-Fi, Low Data Mode) and space problems become `.blocked`; the Home card shows today's choices.
- A failed step returns `.blocked(.failed)`; the next runner tries again (self-healing), and the error is logged.
- A continued task that iOS expires or the person cancels releases its lease; the overnight job finishes the rest.
- Thermal pauses stay in the Indexer (`ThermalGate`); progress keeps reporting through them.

## Testing

- `SetupCoordinator` on macOS with a fake `SetupWork`: derivation after partial work, leases (join, release, last
  release cancels), progress fractions and the creep, outcomes.
- `IndexScheduler.perform(setUp:)`: runs before indexing; a failure still indexes signals.
- App: UI tests on the simulator with the stub loader (setup screen, Home card, continue); a release-check run; a
  TestFlight build on the founder's phone for the continued task, the overnight job and the App Group measurement.

## Implementation notes (2026-11-16)

What the build does, where it differs from or adds to the design above:

- **The coordinator joins the app's existing work, it doesn't replace it.** `AppSetupWork.readyModel` calls the
  existing `loadModel()` when nothing is loading (a retry: self-healing) and waits for `engine`, mapping `modelState`
  to `ModelStep` every 250 ms; `readLibrary` starts the existing indexing loop (`startIndexing`, so the sync reuse,
  type lookups, text and tag passes and living albums stay as they were) and waits for `indexTask` to end, up to three
  rounds. Stopping a run stops the waiting, not the download (it goes on in the background session).
- **Read** means signals and embedding done locally: `assetCount - indexer.pendingCount(includingEmbedding: true)`.
- **A stopped run that a new holder joined while it wound down starts again** (`SetupCoordinator.finish`); a cancelled
  holder leaves at once with `.stopped` while others keep the run.
- **Background hand-off:** on `.background` the foreground lease is released; if the continued task still holds setup,
  indexing isn't flushed and stopped. When the continued task ends with Roll in the background and no lease left,
  `setupRunEnded` flushes and stops indexing and asks for the overnight job, as leaving the screen does.
- **Home card visibility:** while the model isn't attached, or the first full read hasn't finished (`finishedOnce`);
  new photos after that don't bring the card back.
- **App Group:** `group.com.delavalom.roll` ("Roll Shared") created and assigned to `com.delavalom.roll` with
  `asc web app-groups` (founder's web session); new profile "Roll App Store 2026-11-16" (the old one went invalid when
  the group was assigned). Two folders move, not one: Roll's install root (`RollModel`) and the package's store
  (`EmbeddingGemma`, which holds the model and its compiled form once activated, so it's the path the cache keys on).
  `ModelLocation.resolve` moves each once; neither records absolute paths.
- **Keep-awake ships:** `scripts/check_release_no_qa.sh` no longer flags `setIdleTimerDisabled:`; QA's keep-awake is
  still caught by `QAKeepAwake` and `keep_awake`.

### How to measure the App Group experiment

Install build 6 over build 5 from TestFlight (one cold prepare: the model moves to the group's path). Then install the
next build over build 6: if "Getting the AI ready" finishes in about 30 s instead of 7–30 min, the cache survived the
update and the group stays. If it doesn't, keep the entitlement anyway (removing it would leave the installed model
unreachable in the group and cost every phone a new download), or move the folders back with a `ModelLocation` change
before dropping it.
