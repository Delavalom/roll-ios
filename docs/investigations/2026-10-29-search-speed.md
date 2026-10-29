# Search speed (lane L1, 2026-10-29)

Goal (plan `docs/superpowers/plans/2026-10-29-search-and-piles.md`): a preset pile's first 20 cards in **< 50 ms** on
the iPhone 13 Pro Max over ~29.7k embedded items. The proof measured 297–318 ms for unfiltered presets and 103–105 ms
for filtered ones (`evidence/2026-10-29-roll-30k-proof/session2-search.jsonl`), in a **Debug** build.

## How it was measured

`Packages/RollCore/Tests/RankingTests/SearchSpeedBench.swift` (runs only with `ROLL_BENCH=1`; `ROLL_BENCH_OUT` names the
JSON file). World: `SearchBenchWorld.swift`, a temp on-disk GRDB database (WAL, like the app) shaped like the proof
database (aggregates only): 29,685 rows, 29,681 embedded, **256-d** vectors (the app's `GemmaEmbedder` default; the
loader passes no width), 5,190 videos, 2,532 screenshots, 4,055 `isUtility`, a ~3 KB feature print per row (it sits
before `deleted` / `previewSide`, so a row scan reads ~one 4 KB page per asset). Each step of
`SwipefileEngine.candidates` (20 cards) is timed with `ContinuousClock` (`SearchTimings`): `lookup` (stored swipefile),
`sql` (rows), `decisions`, `pool` (filter + alignment), `queries` (cached prompt vectors), `dot`, `score` (+ top 20).
Per preset: a first call, 5 warm calls (median below; min and every run in the JSON), one call after a swipe and one
after an asset write.

Both configurations, because the phone QA builds are Debug (RollCore and EmbeddingIndex at `-Onone`) and the App Store
build is Release: `swift test --filter SearchSpeedBench` and `swift test -c release -Xswiftc -enable-testing ...`.
The Mac was shared with four other lanes building and testing (load average 50–290, in each JSON), so expect noise;
the ratios are stable across reruns.

## Before and after, per step (Mac, warm median, ms)

Receipts = 3 prompts, no filter (29,681 pool). Screenshots = 1 prompt, filtered (2,550 pool). Evidence:
`evidence/2026-10-29-search-speed/mac-before.json`, `mac-step-a.json`, `mac-step-b.json`, `mac-step-c.json`,
`mac-after.json`.

| Debug (`-Onone`, like the phone QA build) | sql | pool | dot | score | **total** | Screenshots total |
|---|---|---|---|---|---|---|
| before (e48da12) | 85.6 | 9.7 | 280.5 | 43.0 | **413.9** | 132.1 |
| (a) one `VectorIndex.dotAll` | 90.6 | 11.1 | 11.8 | 40.7 | **154.9** | 57.2 |
| (b) rows in memory | 0 | 15.0 | 11.3 | 38.0 | **64.9** | 24.7 |
| (c) integer alignment + vDSP scoring (= after) | 0 | 0.01 | 11.0 | 3.9 | **15.4** | 10.1 |

| Release (`-O`) | sql | pool | dot | score | **total** | Screenshots total |
|---|---|---|---|---|---|---|
| before | 46.2 | 2.7 | 20.4 | 7.9 | **82.6** | 67.3 |
| (a) | 42.2 | 3.2 | 4.1 | 5.3 | **53.7** | 34.7 |
| (b) | 0 | 2.5 | 2.7 | 4.1 | **9.6** | 3.9 |
| after | 0 | 0.00 | 2.4 | 0.18 | **3.0** | 1.1 |

`lookup` is ~0.4 ms (debug) / 0.25 ms (release) and `decisions` ~0.09 / 0.05 ms throughout.

When the cached rows can't be used (`mac-after.json`):

| After | Debug total | Release total | Why |
|---|---|---|---|
| right after a swipe | 15.2 | 2.9 | decisions are read per call; nothing else changes |
| right after an asset write | 104.4 | 41.4 | rows re-read (sql ~73 / ~33) and the pile's pool re-aligned (~7–13 / ~0.5–3) |
| first search of a run | 119.0 | 42.9 | same, plus the first id-to-row map; later presets in the run: 18–29 / 1.7–6 |

**What the before split showed.** The handoff's hypothesis (rows read explain the filtered/unfiltered gap) was only
partly right: in Debug the dominant cost was `dot`, one full scored and sorted `search(k: n)` per prompt (280 ms for 3
prompts, 89 ms for 1), so the 300 vs 100 ms gap on the phone is mostly **3 prompts vs 1**. The SQL read was the second
cost (~35–90 ms, every call), then the String dictionaries (pool + lookups in score, ~50 ms).

## What changed

- **(a)** `VectorStore.dotAll` calls `VectorIndex.dotAll` (one `vDSP_mmul`, unsorted). `DotProducts` is now
  **query-major** (`queryCount x ids.count`, like `BulkScores`), with `scores(forQuery:)` and `layout`; the
  `[row, query]` subscript is unchanged.
- **(b)** `CandidatePool` keeps every live row (`Repositories.rankingRows()`: the ranking columns plus `embedded`) in
  memory, stamped with `RankingChanges.generation` read before the read. `RankingChanges` is a GRDB
  `TransactionObserver` on the writer: it counts commits that insert or delete `asset` rows or update a column in
  `Repositories.rankingColumns`; updates of other columns (locality, type lookups, attempts) and rollbacks don't count.
  Decisions are read per call (`decidedAssetIds`, a primary-key range). The preset filter runs in Swift
  (`CandidateFilter.matches`, which the existing tests keep identical to the SQL).
- **(c)** `VectorStore.layout` changes on every `upsert` / `remove`, so `dotAll`'s row order is known to be the same while
  it holds. Each (preset, filter) pool is aligned once per rows generation and layout: per entry its dot row (as a Float
  for `vDSP_vindex`), boost and row index. Decided and on-screen ids become a small `skipped` set. Scoring is
  `vDSP_vmax` over the prompts, `vDSP_vsma` for the example centre, `vDSP_vindex` + `vDSP_vadd`, then a top-20 over
  entry indices (ties by id, as before). The trained path gathers the classifier dots the same way.
- `preparePools(for:)` reads the rows and aligns the given presets ahead of time, so the first pile opened skips the
  read. Not wired in the app (AppModel belongs to L5): call it after `attach` once indexing is idle.

Correctness tests (`CandidatePoolTests`, `RankingChangesTests`, `RankingSupportTests`): a warm call reads no rows;
decisions (through the engine or written elsewhere), undo, deletions plus the vector purge, newly embedded assets, a
vector saved before its flag, a library metadata change, a flagged row whose vector is missing, and a freed slot reused
by another vector all show up correctly on the very next call; scores still equal `Scorer`'s.

## What is left, by measured cost

1. **`dot` in Debug (~11 ms of the 15).** It is `VectorIndex.dotAll` in EmbeddingIndex at `-Onone`: the matrix product is
   ~1 ms; the rest is its per-call `live` filter, `ids` array and query transpose in Swift loops. Release: 2.4 ms. Fixable
   only in embeddinggemma-coreml (not this lane), e.g. cache `ids` between mutations.
2. **The read after a ranking-relevant write (~73 ms Debug, ~33 ms Release on the Mac).** A covering index (`deleted` first, then
   the ranking columns) makes the same read ~4.5x faster on the proof database (31–32 ms → 7 ms, sqlite3 CLI:
   `evidence/2026-10-29-search-speed/sqlite-covering-index.txt`). That is a schema migration (Schema belongs to L3's v10);
   a candidate for v11 if the phone shows the post-write search over budget.

## What the phone run must confirm

Debug build, `-QAMetrics -QASearchBench`: each `search` event now carries `pool` and `<step>_ms` for `lookup`, `sql`,
`decisions`, `pool`, `queries`, `dot`, `score`, `total` (DEBUG only, no identifiers).

- Attempts 2–5 of every preset: `total` < 50 ms (Mac Debug: 10–15 ms), `sql_ms` = 0.
- Attempt 1 of the first preset: `sql_ms` is the cold read (Mac Debug ~76 ms); other presets' attempt 1: `sql_ms` = 0.
- `dot_ms` for 3-prompt presets about the same as 1-prompt ones (one matrix product either way).
- If `total` misses the goal, the split says where: `dot` (EmbeddingIndex in Debug) or `sql` (the covering index).
