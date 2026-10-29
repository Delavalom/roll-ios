# Device QA, 2026-10-23: follow-up fixes and the re-run

Part of [Device QA, 2026-10-23](../device-2026-10-23.md).

## Follow-up fixes (branch `feat/icloud-honest`)

The coordinator's decisions on the top Part 1 problems, implemented with public APIs only (no KVC on `PHAssetResource`). Device re-measurement is pending: the phone stayed locked.

| # | Problem (Part 1) | Change | Before (measured) | After |
|---|---|---|---|---|
| 1 | 98.4% of thumbnails iCloud-only; 1.6% of assets analysed; blank swipe cards | Without network, image requests are opportunistic and keep the degraded local preview (`ThumbnailResult.preview`); iCloud-only videos use their poster preview. The Indexer analyses and embeds previews; Store v6 records `source` (`preview`/`full`). Swipe cards read the same preview. Opt-in "Improve with iCloud originals" (Home, off by default) re-analyses preview rows on Wi-Fi while charging (`run(allowNetwork: true, upgradePreviews: true)`). | 476 of 29,589 analysed (1.6%) | To measure: `index_batch.analysedShare`, `store_stats.sourcePreview`. Depends on how many previews Photos keeps locally (`-QAThumbProbe`). |
| 2 | "You can free about 39.57 GB" on a phone with 9.3 GB free | `CleanupSummary.freeableOnDevice` / `freeableInCloud` from `AssetRecord.locality` (what the Indexer saw with network off: `cloudOnly` = original in iCloud). The headline shows on-device bytes only, capped at total − available; iCloud originals get their own line. The Monitor shows "on this iPhone" (capped) and "Originals in iCloud". | 39.57 GB headline; 183.2 GB "estimate" under a 115 GB gauge | To measure: `home.headlineBytes`, `home.freeableOnDevice`. |
| 3 | Squish preselected 12,031 iCloud items, "saves about 77.71 GB"; Dolby Vision refused only at export | Only on-device items start selected (`SquishCatalog.defaultSelection`). `SquishFormatScreen` reads each local video candidate's track format once per launch (the same `VideoSquisher.unsupportedFormat` check: `dvh1`/`dvhe`/... or DV atoms; network off) and remembers Dolby Vision as "HDR video kept as is" (with a count), so it's out of the list, the selection and Home's savings. | 12,031 preselected | To measure: `squish_catalog.defaultSelection`, `hdrKept`, `selectedSavings`. |
| 4 | Thermal `serious` 48 s into the launch library read | `fetchAll` and the per-asset UTI lookup run at utility QoS in pages of 500 with yields; the second full sync right after the taste scan is skipped (it repeated a read of every asset). The taste scan already waits for its sync before indexing; the Indexer still pauses at `serious`. Timings: `sync_read` events. | serious at 48 s; 266 of 600 s paused | To measure. Instruments wasn't possible (phone locked). |
| 5 | Screenshots estimated at 1.6 B/px (11.24 GB for 2,523) | Screenshots use 0.40 B/px, the maximum of 16 real 1284×2778 PNG captures from this iPhone (median 0.12). Never above the container's own rate. Squish and Home use the same `estBytes`. | 4.46 MB per screenshot on average; 11.24 GB for 2,523 | 1.43 MB per 1284×2778 PNG screenshot (was 5.71 MB). For PNG screenshots the total scales by 0.40 / 1.6 = 0.25, about 2.8 GB for the same 2,523; the exact figure comes with the next device sync |
| 6 | Squish rows wrapped into columns; "about 0 MB" rows; Monitor's 183 GB row | Squish rows are one size line (scales down) and one joined subtitle (wraps as text); zero-size cards, taste-scan rows and the queue footer hide the size; Monitor rows relabelled as above. | | Screenshots pending. |

The seeded simulator smoke test (onboarding → taste scan → swipe 5 → apply → system delete prompt → count drops by 5) passes on this branch.

Tests: 583 RollCore tests pass, including new ones for previews, v6, the upgrade pass, the on-device split and cap, local-only selection, the Dolby Vision screen and the screenshot rate. `ROLL_WITHOUT_GEMMA=1 swift test` covers only Library, Signals and Monitor (96 tests), so the Store, Indexer, Overview and Squish tests ran in the full package while memory was 35–46% free.

### Review fixes (same branch)

An independent review of `5a77cbe...feat/icloud-honest` found no Critical issues and 7 Important ones. All are fixed:

1. `-QAAlbum` with an empty or missing title now always makes a QA runtime, read-only (every change refused), logged as a fault and shown with a red badge.
2. Migration v7 (new; v6 may already have run on the device): `cloudOnly = 0` for rows that were never analysed and have no source, so the local preview pass picks them up. Also adds `asset.previewSide` and the `videoProbe` table. Tested from v5 and v6 databases.
3. Locality only from an offline request: thumbnails are always requested with network off first; only what didn't come back full is downloaded, and a download is recorded as in iCloud (`cloudOnly = 1`, `source = full`).
4. Wi-Fi (not expensive, not constrained) and charging are watched for the whole upgrade pass (`ICloudUpgradeSupervisor` + `ICloudUpgradeMonitor`). The Indexer is cancelled as soon as either fails, and the pass resumes when both hold again.
5. (a) A video adds squish savings only after its format passed the probe; unprobed ones count only as deletion candidates. (b) At launch, the largest items behind the on-device headline (budget 500, utility priority, network off; `requestImageDataAndOrientation` / `requestAVAsset`) are re-checked, and offloaded ones move to iCloud. The used-space cap stays as a backstop.
6. Blurry (and any quality filter, in Swift and SQL) skips rows analysed from a preview smaller than 256 px (`BlurScore.analysisSide`) or of unknown size.
7. Passing probes are stored per asset, keyed by `modified`. Squish lists items immediately and probes in the background, in one non-overlapping task. A video starts selected only after it passed.

Minor fixes: a degraded preview counts only when the final call reports iCloud or an error; a video is marked probed only after an answer; `QAPause` keeps one continuation per caller.

Checks: 604 RollCore tests pass, and the seeded simulator smoke test passes. A Release build has no QA strings and an empty `RCTestStoreKey`. Only public APIs are used.

## Device re-run, 2026-10-24 (branch `feat/icloud-honest`)

Same iPhone 13 Pro Max, iOS 27.0.1, on the cable (charging 85–96%). The read-only cases ran in one `xcodebuild test-without-building` with the screen kept on by Roll (DEBUG QA mode). Screenshots are in `artifacts/qa/shots/run3/` and `run5/` (gitignored); metrics are in sessions 7–17 of the pulled `metrics.jsonl`.

### "Roll QA" album: destructive cases not run

The album exists with **44 items, over the 40 limit**, so D1–D5 did not run. Contents (no identifiers): 28 JPEG photos, 13 PNG screenshots, 1 PNG, 2 HEIC photos. **No videos.** Only **2 of 44 originals are on the phone**; the rest are in iCloud. Up-front squish refusals: 2 `unsupportedFormat` (the HEICs) and 1 `burst`. No JPEG/PNG is over 3 MB locally, so even within the limit there would be no squish candidate, and no Dolby Vision or HEVC clip for the export experiment. A second check about 45 minutes later found the same 44 items with identical contents. **HEIC/Dolby Vision export, the read-back SHA-256 check (case 14) and metadata survival remain unmeasured.**

The album check also measured the preview path on its 42 indexed items: **40 analysed from local previews, 2 full, 0 skipped** (100%).

### Part 1 before / after

| | Before (2026-10-23, main) | After (2026-10-24, this branch) |
|---|---|---|
| Assets analysed | 476 of 29,589 (1.6%) | **21,574 of 29,594 (72.9%)** when the 15-minute budget ran out, still indexing: 21,182 from previews, 392 full. Only 132 of 24,200 thumbnail requests (0.5%) had no local preview. |
| Indexing rate | 272 items/s (almost all skips) | 112.5 items/s median per batch of real Vision work; about 24 items/s wall-clock with thermal pauses. Vision costs a median 7.1 ms per image (p90 10.3 ms). 50k assets: about 7.4 min of compute, **about 35 min wall-clock** at this pause rate. |
| Headline | "You can free about 39.57 GB" | "You can free about **117.5 MB** on this iPhone" (176.9 MB mid-run, before the verifier), plus "about 40.18 GB of originals stored in iCloud" |
| Screenshots estimate | 11.24 GB (2,523) | 2.81 GB (×0.25, as calibrated) |
| Squish default selection | 12,031 items, "saves about 77.71 GB" | **6 items, about 25.9 MB** (10,012 listed; 8,400 iCloud ones not selected). The 309 big videos are in iCloud, so none was probed and none adds savings. |
| Launch library read | about 60 s for the whole sync; thermal serious at 48 s | fetchAll 31.6 s + UTI lookups for 29,594 assets 62.4 s = **94 s**; thermal still **serious at 45 s**. Utility QoS made the read slower without keeping it cool, and the phone was charging. |
| Thermal pauses | 266 of 600 s (44%) | 889 of 1,299 s (68%): now doing real work; "serious" 8 times |
| Locality verifier | – | checked 92, **demoted 68 (74%)** in 3.6 s. A full 960 px image without the network didn't prove the original was local. |
| Peak memory | 167 MB | 235 MB in Part 1; up to 314 MB on later launches with the full index. Budget 800 MB. |
| Duplicates / Similar shots | 8 / 21 extra | **697 / 6,427 extra** (1,953 similar groups, the largest 132). Grouping on about 120 px previews over-groups: a new problem. |
| Blurry | 10 | 34 (previews below 256 px excluded) |
| Swipe cards | blank | show the preview, visibly soft (about 120 px upscaled) |

### Thumbnail probe (network off, 200 newest and 200 spread)

| Request | Newest: local / iCloud | Spread: local / iCloud | Size delivered |
|---|---|---|---|
| 960 high quality (old indexer) | 30 / 170 | 8 / 192 | 960 |
| 900 high quality (swipe card) | 30 / 170 | 8 / 192 | 900 |
| 512 high quality | 121 / 79 | 88 / 112 | 512 |
| **300 high quality** | **200 / 0** | **200 / 0** | 300 |
| 960 fast format | 200 / 0 | 200 / 0 | median 120 |
| 960 opportunistic (current indexer) | 30 full + 170 degraded | 8 full + 192 degraded | **median 120** (degraded) |

The previews the indexer now accepts are a median **120 px**. A plain 300 px high-quality request is answered locally for **every** asset, and 512 px for 44–60%. Asking 960 → 512 → 300 would give the indexer, the blur check (256 px) and the cards a usable image with no network.

### RevenueCat Test Store (`-RCTestStore`): pass

- With the free quota used up, the plan said "14 more items need Roll Pro" and Apply was disabled (`p3-01`).
- The paywall showed Annual US$29.99/year and Weekly US$4.99/week, with no trial, as expected for the Test Store (`p3-02`).
- RevenueCat's "Test Store Purchase" sheet for `roll_pro_weekly`: "Test valid purchase" (`p3-03`).
- Pro unlocked: the paywall closed and the plan became "Delete 2 items", enabled (`p3-04`). Nothing was applied (Cancel; the read-only gate would also refuse).
- Restore: the paywall closed with "Pro restored" (`p3-06`).

Two copy notes: the blocked line says "need Roll Pro" in the plural, and a delete can be held back to keep the last shot of a duplicate set.

### Large text (XXXL, accessibility L)

Home, Monitor and the paywall reflow well. **The Squish row truncates at accessibility sizes** ("about 2.99…", "Video ·") because of its one-line size label: allow two lines at accessibility sizes. The Monitor labels read clearly ("Photos and videos on this iPhone about 975.9 MB", "Originals in iCloud (not counted above) about 144.71 GB").

### Run notes

- The first attempt (run2) was disturbed: Roll was reopened from Photos mid-test (the "◀ Photos" breadcrumb is in the recording). The taste scan was cancelled and onboarding never finished, so that run's results were discarded. The onboarding step now returns to Roll and waits for a tappable Continue.
- Part 1's scroll gestures landed on a swipe pile when "back" didn't leave it, queuing 12 "add to album" decisions in Roll's own database. The test now checks it has left the pile. At the end, Roll's state was reset on the phone to clear the 14 queued but unapplied decisions, so the next launch shows onboarding. The library itself was never changed.
- Since the album check, Roll's metrics show only the launches made by these runs. The album's contents didn't change between the two checks, so there are no signs of other QA-mode use. Launches from the home screen record nothing, so ordinary use can't be ruled out.

### New problems, ranked

1. **Over-grouping on 120 px previews:** 6,427 similar extra shots (largest group 132) and 697 duplicates. Feature prints and hashes from tiny previews link unrelated photos. Use the 300 px local image (100% local) and apply the preview-size guard to grouping too.
2. **Locality from a 960 px thumbnail is wrong 74% of the time** (verifier). Base the on-device signal on the original (`requestImageDataAndOrientation`, network off), as the verifier does, instead of the thumbnail.
3. **Heat:** the launch read is slower at utility QoS (94 s against about 60 s) and still reaches serious at 45 s; indexing spends 68% of the time paused while charging. Look up UTIs lazily (only for squish and size candidates), and repeat the run unplugged.
4. Swipe cards are soft (120 px previews upscaled): use 512, then 300 px local requests.
5. The Squish row truncates at accessibility text sizes.

