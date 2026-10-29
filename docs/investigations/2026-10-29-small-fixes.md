# Small findings from the 30k proof (handoff §4), lane L5 (2026-10-29)

Three items from `2026-10-29-fixes-HANDOFF.md` §4. Counts come from the proof's database copy
(`~/egcm-evidence-raw/2026-10-29/roll-proof/db/roll.sqlite`, private) and logs; no identifiers here.

## 1. Same build number skipped "Preparing search": fixed

- **Cause.** `prepareIfNeeded`'s marker was `<revision> <version> (<build>)`. iOS's Neural Engine cache key includes the
  compiled model's path and inodes (embeddinggemma-coreml `docs/investigations/2026-10-27-ane-cache.md`, finding 3), and
  the path is inside the data container, which every install and `devicectl` update moves. The proof's second install
  kept the build number, so the marker matched, nothing prepared, and the first search compiled the text function inline
  (52.5 s, `2026-10-29-roll-30k-proof.md` §3).
- **Fix.** `Embedding/SearchPreparation.marker(revision:version:build:container:)` (pure, `SearchPreparationTests`)
  adds the data container path (`NSHomeDirectory()`); `App/AppModel+Model.swift` uses it. The data container is the actual
  key input; `Bundle.main.bundleURL` also changes per install but isn't what the cache keys on.
- **Effect.** The first launch of a build with this change prepares once (the marker's format changed), which a new build
  number would have caused anyway. App code: compile-check at integration.

## 2. 19,512 assets with unknown file type: not a lookup gap

The lookup covered every row it is meant to. `asset.uti` NULL on live rows, by why it was never looked up:

| Rows | Why no type | Matters for Squish or sizes? |
|---|---|---|
| 5,190 | videos: `typeLookupCandidates` takes `mediaType = 1` only | No: video candidacy and estimates use `estBytes` and bitrate, never `uti` |
| 10,103 | photos under `typeLookupMinimumPixels` (1.875 MP: 3 MB at PNG's 1.6 B/px) | No: can't reach Squish's 3 MB minimum in any type it takes; sized at 0.6 B/px (`smallUntypedCentibytesPerPixel`) |
| 4,219 | photos at or over 1.875 MP with an excluded subtype (Live, Portrait, animated, spatial, screenshot) | No: Squish never takes them (`typeLookupExcludedSubtypes`) |
| **0** | photos `typeLookupCandidates` would still select | – |

The 10,173 photos that needed a type all have one (8,185 JPEG, 1,913 HEIC, 73 PNG, 2 WebP), matching the 10 × 1,000 + 173
`types_resolved` events in the raw log. So the proof doc's "the file-type lookup didn't run for most rows" was a misread of
`store_stats.byUTI`, whose NULL bucket is named "unknown".

**Proposed fix (not implemented, QA-only):** split that bucket in `Repositories.qaStats` (`Store/Repositories+QA.swift`)
into `typeNotNeeded` and `typePending`, pending being what `typeLookupCandidates` would return. It needs Indexer's
thresholds passed in from `App/QA/QAMetrics.swift`, so it touches the QA wiring for a label only; left for whoever next
edits QA metrics.

## 3. A dozen empty index runs right after finishing: found and fixed

- **Trigger.** `AppModel.startIndexing`'s loop. After a run it looks up file types in batches of 1,000
  (`typeLookupBatch`), and when a batch resolved anything it set `indexAgain = true`, so each batch went round the whole
  loop: a library sync (skipped within `syncReuse`, 600 s), `indexer.run()` with nothing pending, then the next batch.
- **Evidence.** Raw log (`~/egcm-evidence-raw/2026-10-29/roll-proof/qa/metrics.jsonl`): `types_resolved` 1,000 at up
  5,596.5 s, then 9 more of 1,000 and one of 173 between 5,638.1 and 5,658.8 s, each followed by an `index_run`
  started/finished pair with `total: 0`, ~0.05 s (`evidence/2026-10-29-roll-30k-proof/session1-model-and-runs.jsonl`,
  up 5,635.5–5,658.9 s): 11 batches, 11 empty runs. The first round also re-read the whole library: the last full sync was
  75 min old, so `sync()` ran (phase `syncing` from 5,597 to 5,635 s, 38 s, the phone `serious`).
- **Fix** (`App/AppModel.swift`, L5's file): the type batches run in an inner loop (until a batch comes back short or
  the task is cancelled), so no extra rounds, empty runs or stale-sync re-reads. A change arriving meanwhile still sets
  `indexAgain` and gets its own round after the batches. App code: compile-check at integration.
