# Handoff: search speed, Similar shots, Blurry (written 2026-10-29 after the 30k proof)

Read first: `2026-10-29-roll-30k-proof.md` (the measurements). This handoff is the starting point for a discussion with
the founder, who has their own ideas for search, indexing and categories and wants to go through them in detail before
anything is built. **Do not start coding these fixes before that conversation.** Rules that still apply: evidence, not
guesses (one variable per experiment, every number with its file); the 5k-token commit hook; Debug-only QA code.

Private evidence (not in the repo, has photo identifiers): Roll's database copied from the phone after the proof,
`~/egcm-evidence-raw/2026-10-29/roll-proof/db/roll.sqlite` (+ `-wal`, `-shm`), and the full metrics log next to it.
Query it read-only; never copy identifiers into the repo.

## 1. Search: ~300 ms per search over 29,681 photos (goal: milliseconds)

Measured (`evidence/2026-10-29-roll-30k-proof/session2-search.jsonl`): 297–318 ms for presets that rank every embedded
photo, 103–105 ms for presets that pre-filter (Screenshots: 2,532 rows; Blurry: 2,877). The query embedding is not
in these: `SwipefileEngine.promptVectors` caches each swipefile's prompt vectors (the uncached embedding is 6.7 ms,
embeddinggemma-coreml s6). So the time is Roll's ranking path, `SwipefileEngine.candidates`
(`Packages/RollCore/Sources/Ranking/SwipefileEngine.swift`), per search:

1. `repositories.rankingCandidates` (`Store/Repositories+Ranking.swift`): a SQL read of every candidate row (10 columns,
   String ids) with a `NOT EXISTS (decision …)` per row, materialised into `[RankingAsset]`.
2. A `[String: PoolEntry]` dictionary of all of them.
3. `VectorStore.dotAll` (`Store/VectorStore.swift:182`): for each query it calls `index.search(q, k: n)` with `k` = the
   whole index, i.e. a full scored and sorted list of 29,681 hits per prompt (Memes and Receipts have 3 prompts), plus
   a `[String: Int]` map for queries after the first.
4. Score, filter by floor, `top(limit)`.

Unmeasured so far, so the split is a hypothesis: the ~200 ms difference between filtered (2.5k rows) and unfiltered
(29.7k rows) presets points at steps 1–2 (rows read); the ~100 ms floor is shared and includes step 3 over the whole
index. 29,681 × 256 floats is 7.6 M multiply-adds, a few ms with Accelerate, so a full sort per query and String
handling are the likely cost of step 3.

First experiment (one variable at a time, with `os_signpost` or `ContinuousClock` around each step, logged by
`QASearchBench`): time steps 1–4 separately on the phone, warm, 5 runs each. Candidate fixes to discuss, by expected
gain: keep the candidate pool (ids, boosts, filters as bitsets) in memory and update it on index/decision changes
instead of reading SQL per search; score with one matrix-vector product over a contiguous `Float` buffer (vDSP/BNNS)
and a partial top-k instead of `search(k: n)`; integer row ids instead of String ids in the hot path.

## 2. Similar shots: 10,225 "extra" in 2,835 groups, largest 175 (44 % of the library grouped)

How grouping works (`Packages/RollCore/Sources/Dedupe/DuplicateGrouper.swift`): records created within `window` = 120 s
of each other are compared (up to `maxNeighbors` = 24 successors); two link if their perceptual hashes differ by
≤ 4 bits or their Vision feature-print distance is < `fpThreshold` = 0.35; bursts are unioned outright; links are
merged with union-find, so groups are **transitive**: A~B and B~C put A and C together even if they look nothing alike.

Measured on the founder's library (the database above): 17,384 of 24,495 images sit in chains of photos less than
120 s apart (3,188 chains; the longest 196, then 131, 118, 113, 105, 90), and 5,445 images share an exact timestamp
with another (saved from messaging apps). Only 24 burst ids, each of 1, so bursts are not the cause.

Hypothesis (to test, not yet shown): within those long time chains, a 0.35 feature-print threshold plus transitive
merging chains loosely similar photos (same chat, same screenshot style) into large groups. Tests: the distance
distribution of linked pairs in the 175-member group; group sizes with `fpThreshold` 0.25/0.30 and with
complete-linkage or "link to the group's first member" instead of union-find, on the copied database (feature prints
are in `asset.featurePrint`). The founder's screenshots of the big group decide what "similar" should mean.

## 3. Blurry: 2,877 items, 40.3 GB, but only 122 are blurry

The Blurry preset's filter is `blur < 25 OR aesthetic < -0.3` (`Ranking/Presets.swift:54`, SQL in
`Store/RankingAsset.swift`, `CandidateFilter.sql`), on rows analysed from ≥ 256 px. On the founder's library:

| | Images | Videos |
|---|---|---|
| `blur < 25` (actually blurry) | 67 | 55 |
| `aesthetic < -0.3` (low aesthetic score) | 1,133 | 1,736 |
| Either (what Home shows) | 1,139 (3.5 GB) | 1,738 (36.8 GB) |

So "Blurry" is mostly low-aesthetic videos. Fix to discuss: Blurry = `blur < 25` only (images, and videos only if the
founder wants them); a separate, clearly named "Low quality" pile if the aesthetic score is useful at all (look at
samples first); never count videos' bytes under Blurry by default.

## 4. Smaller findings from the same run

- **Same build number skips "Preparing search".** Installing over the app with the same build moved the container
  (new Neural Engine cache key) but `AppModel.prepareIfNeeded`'s marker (model revision + version/build) matched, so the
  first search compiled the text function inline: 52.5 s. Real installs and updates change the build number, so users
  don't hit it; Debug installs and TestFlight builds with a reused build number do. Option: add the data-container path
  (or `Bundle.main.bundleURL`) to the marker, which changes on every install.
- **File types unknown for 19,512 assets** (`store_stats.byUTI`, proof doc): the type lookup rounds didn't cover most
  rows. Squish estimates depend on it.
- **Indexing is thermal-bound**: 62 % of the 75.8 min was `serious`, 46 pauses; unpaused it would be ~27 min. The phone
  was charging. Ideas: fewer Vision requests per photo, smaller analysis size, pausing at `serious` only, an unplugged
  comparison run.
- **Index loop churn after finishing**: after the full run, a dozen empty index runs started and finished within
  ~25 s (`session1-model-and-runs.jsonl`, up 5,636–5,659 s). Harmless here; check what triggers them.

## Questions for the founder (bring these to the session)

1. What should "search in milliseconds" mean: the time to show the first results of a pile, or of a typed query?
   Target number?
2. Similar shots: after looking at the 175-member group, what should count as similar (same moment, same scene, near
   copies)? Is a looser pile useful if it's named differently?
3. Blurry: only truly blurry photos? Should videos ever be in it? Is a "low quality" pile wanted?
4. Their own ideas for search, indexing and categories (this session should start with them).

## State

- roll-ios `main` has Job 3 merged (per-budget packages, one-at-a-time preparing) and the proof's QA tools
  (`-QASearchBench`, the Debug-only `artifacts/local-model/` bundling step). The proof build is still installed on the
  founder's phone with the full index, so new search or category code can be measured without re-indexing: install
  over it (data kept), expecting the text and image functions to compile once on first use (see the build-number note).
