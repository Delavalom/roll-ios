# Device QA, 2026-10-23: measurements

Part of [Device QA, 2026-10-23](../device-2026-10-23.md).

## Hardware and library

- iPhone 13 Pro Max (`iPhone14,3`), iOS 27.0.1, 6 cores, 5.91 GB RAM. Volume 115.09 GB (sold as 128 GB), 9.35 GB available for important usage, 6.27 GB plain available.
- Started at 95% battery, charging (100% at the end). Optimize iPhone Storage is evidently on (see below).
- Library (PhotoKit counts, no identifiers): **29,589 assets**: 24,429 photos, 5,160 videos (about 41 hours of video). 2,523 screenshots, 2,169 Live Photos, 69 HDR-flagged photos, 19 Portrait, 16 panoramas, 30 screen recordings, 9 slo-mo, 1 time-lapse, 0 cinematic. 380 favorites, 0 hidden, 23 user albums.
- By container (Store UTIs): JPEG 18,066, HEIC 3,713, PNG 2,633, MPEG-4 4,256, QuickTime 904, WebP 13, GIF 4. Mostly JPEG and MP4, so much of the library comes from messaging apps rather than the camera.
- Model status: "not ready (unavailable)" 2 s after launch, as expected (the model isn't published).

## Indexing throughput

| Run | Assets | Time | Rate | Thumbnails iCloud-only |
|---|---|---|---|---|
| Launch sync (enumerate + UTIs, 29,589) | | about 60 s | | |
| Taste scan (`run(limit: 500)`) | 500 | 106.5 s | 4.7 /s | 463 of 500 (92.6%) |
| Full index | 29,089 | 279.8 s | 104 /s | 28,650 of 29,089 (98.5%) |

- Per 200-item batch: 147 batches, median 272 items/s (min 1.9, max 655). Those rates are almost all skips: a thumbnail request with network access off returns "in iCloud" in a few milliseconds.
- **Only 476 of 29,589 assets (1.6%) got Vision signals.** 29,113 rows are `cloudOnly`; none failed. The app never retries them: `AppModel.startIndexing()` calls `indexer.run()` without `allowNetwork`, and nothing else does either. So Duplicates, Similar shots and Blurry describe 1.6% of the library.
- Thermal pauses took 266 of the 600 sampled seconds. The taste scan sat in a pause from 69 s to 168 s, which is most of its 106 s.
- **Extrapolation for 50k assets:**
  - this phone as configured: about 100 s of sync, then about 3 minutes of skipping, and still about 1.6% analysed;
  - with local thumbnails, the cost is the per-image signal time, which this run couldn't isolate (only about 33 local images in the first batch, inside a thermal pause). The `-QAThumbProbe` run measures it (`signal_timing`); until then there's no honest number. At an assumed 30–60 ms per image (blur + aesthetics + feature print + hash on 960 px), 50k would take 25–50 minutes of foreground time plus thermal pauses. This assumption is unverified.

## Memory

- `phys_footprint` sampled every second (600 samples): median 57 MB, p95 103 MB, **peak 167 MB** (at the start of the full index). By phase: sync max 166 MB, indexing max 167 MB, idle 23–26 MB.
- `os_proc_available_memory` + footprint puts the jetsam limit at about 3,072 MB.
- **Budget:** Roll's spec has no memory budget. The only one in the specs is the embedding package's s6 gate (`embeddinggemma-coreml` design §, s6_device): **peak RSS ≤ 800 MB**. Roll is at 21% of that without the model. The model (about 300 MB download) and the 50k × 256 vector index (51 MB) aren't loaded here, so re-measure once the model is published.

## Thermal and battery

- Thermal: nominal → fair at 28 s → **serious at 48 s** (during the launch sync, before any Vision work) → nominal at 168 s → fair → **serious at 233 s** → fair → nominal → fair → **serious at 363 s** → fair → nominal at 558 s.
- Battery 95% charging → 100% charging. Charging adds heat; repeat one run unplugged to separate the two.
- The Monitor's battery reads 95% while the status bar shows 97%: `UIDevice.batteryLevel` moves in 5% steps. Expected, but the UI could say "about" or round the same way.

## Home numbers

Final Home (`p1-04-home.png`): **"You can free about 39.57 GB"**; 29,589 photos and videos, about 183.2 GB.

| Category | Count | About |
|---|---|---|
| Duplicates | 8 extra copies (7 groups, 15 members, largest 3) | 13.2 MB |
| Similar shots | 21 extra shots (17 groups, 38 members, largest 4) | 76.6 MB |
| Screenshots | 2,523 | 11.24 GB |
| Blurry | 10 | 42.3 MB |
| Big videos | 308 (45.68 GB full size) | squish saves 28.20 GB |

- **Arithmetic: correct.** 11.243 + 0.042 + 0.013 + 0.077 + 28.197 = 39.57 GB = `freeableBytes` (big videos count at their squish savings, as designed).
- **Plausibility: no.**
  1. The library estimate (183.2 GB) is larger than the phone (115 GB, 9.3 GB free). With Optimize iPhone Storage the originals are in iCloud, so deleting or squishing them frees iCloud space, not much iPhone space. "You can free about 39.57 GB" on a phone with 9.3 GB free reads as a device-space promise that can't be kept.
  2. Screenshots average 4.46 MB each (PNG estimate 1.6 B/px × 3.57 Mpx). Real iPhone 13 Pro Max PNG screenshots are usually 1–3 MB, so this is likely 1.5–4× high.
  3. Big-video savings assume every big video is squishable. iPhone videos recorded with HDR on (the default) are Dolby Vision and are refused at export, and all of them are in iCloud with downloads off. Most of the 28.2 GB can't be delivered.
  4. Duplicates, Similar and Blurry cover only the 476 analysed assets.
- The taste scan header (39.44 GB) covers the whole library's metadata, not the newest 500, and its rows don't add up to it: "Big videos about 45.68 GB" (full size) next to a total that uses 28.2 GB of savings. "Duplicates and similar shots about 0 MB" and "Blurry about 0 MB" appear because only 37 of the 500 had local thumbnails (`p1-01-taste-scan-result.png`).
- The Squish screen (`p1-05-squish.png`) offers **12,031 items, all preselected, "saves about 77.71 GB"**. Home says big videos save 28.2 GB. Both are "about", but they disagree by 50 GB because Squish adds JPEG/PNG photos over 3 MB. Every visible row is "in iCloud" and downloads are off, so tapping it would queue 12,031 items that would all be refused with `needsDownload`.

## Screenshot review

| Screen (file) | Finding |
|---|---|
| Screenshots / Blurry swipe (`p1-05-screenshots.png`, `p1-05-blurry.png`) | **The top card is blank** (grey and black). Cards request a 900 px image with network access off; for an iCloud-only asset that returns nothing, and there's no fallback to the local low-res image or a cloud placeholder. On this library almost every card would be blank. |
| Squish (`p1-05-squish.png`) | Row subtitle wraps into three narrow columns ("Video · 1080p (from 1440p) · in iCloud"): the `HStack` of three `Text`s has no line limit or layout priority. Size line wraps "about 2.99 GB → about / 977.3 MB". 12,031 items preselected by default. |
| Taste scan (`p1-01-taste-scan-running.png`, `-result.png`) | "Reading your library…" with no progress for about 60 s (the sync). "about 0 MB" rows. Header vs rows mismatch (above). |
| Home (`p1-04-home.png`) | "You can free about" and "39.57 GB" break across lines at the default text size (fine, but the size dominates). The last card sits under the floating tab bar until you scroll (normal for iOS 26+ tab bars). "Your swipefiles · about 0 MB" when nothing is queued: hide the size at zero. |
| Monitor (`p1-07-monitor*.png`) | "Photos and videos (Roll's estimate) about 183.2 GB" under a 115 GB storage gauge reads as an error; label it as originals including iCloud, or hide it with Optimize Storage. Per-core CPU bars are flat 3 px lines at low load (fine). Battery quantised to 5% (above). |
| Duplicates / Similar (`p1-05-duplicates*.png`, `p1-05-similar*.png`) | Fine: thumbnails load (these are local items), sizes read clearly. |
| Paywall in onboarding (`p1-02-paywall-onboarding.png`) | Real RevenueCat sandbox offering loaded: Annual "3 days free, then $29.99/year", Weekly "$4.99/week", Terms and Privacy links. No layout problems at the default size. |
| Swipefiles (`p1-06-swipefiles.png`) | Fine. |

Dynamic Type at XXXL and AX-L wasn't captured yet (`testP2PaywallAndLargeText` is ready).

## Monitor vs Settings

| Monitor | Value | System source | Settings |
|---|---|---|---|
| Storage | 9.31 GB available of 115.09 GB (92%) | `volumeAvailableCapacityForImportantUsage` (includes purgeable) | Settings > General > iPhone Storage shows used of **128 GB** (decimal marketing size), and its free figure includes purgeable space too. The capacities differ by design (formatted volume vs marketing size); the user should compare the free figure (step M0). `volumeAvailableCapacity` was 6.27 GB and opportunistic 0.93 GB, so the Monitor shows the most generous of the three, as Settings does. |
| Memory | 4.09 GB of 5.91 GB (69%) | active + wired + compressed pages vs `physicalMemory` | Settings shows no RAM figure. |
| CPU | 3–5%, 6 cores | `host_processor_info` ticks | n/a |
| Thermal | Normal | `ProcessInfo.thermalState` | n/a |
| Battery | 95% charging | `UIDevice` (5% steps) | Status bar showed 97% |
| Up for | 13 h 50 min | `systemUptime` (49,740 s) | consistent |

