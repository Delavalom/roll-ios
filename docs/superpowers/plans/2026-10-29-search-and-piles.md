# Plan: fast search, honest piles, words in images (2026-10-29)

Inputs: `docs/investigations/2026-10-29-roll-30k-proof.md` (measurements), `docs/investigations/2026-10-29-fixes-HANDOFF.md`
(code paths, hypotheses), and the DigUp review (github.com/ARahim3/DigUp, MIT; local copy `/tmp/digup-src/DigUp`,
`Sources/DigUpKit/Searcher.swift`). Ideas are free to reuse; copying DigUp code needs its MIT notice, so write our own.

## Founder decisions (2026-10-29, this session)

- **Search goal** on the iPhone 13 Pro Max over ~30k items: a pile shows its first cards in **< 50 ms**; a typed
  query (including the ~7 ms text embedding) answers in **< 100 ms**.
- **Similar shots** = same moment + same scene: every member close to the group's first shot, within a short span.
  **No transitive chaining.**
- **Blurry** = `blur < 25`, **photos only**. Low aesthetic score no longer puts anything in Blurry. No "Low quality"
  pile until the founder has seen samples.

## How the ideas blend

| Idea (source) | Lane | Why it fits now |
|---|---|---|
| ~300 ms search: full sorted search per prompt + SQL pool per call (handoff §1) | L1 | `VectorIndex.dotAll` (one `vDSP_mmul`, unsorted) already exists in EmbeddingIndex; Roll's `VectorStore.dotAll` still runs `search(k: n)` per query. |
| Per-query scale instead of the fixed 0.2 cosine floor (DigUp 1) | L2 | Every vector is scored anyway, so mean/sd per query are free. Gives honest "nothing found" for typed queries. |
| Fold weak matches under "N weaker matches" (DigUp 3) | L2 | Same pass: `score >= ratio × top` (DigUp: 0.5). |
| Typed query on Home ("Ask Roll" A) | L2 (engine), UI later | Engine API only here; the Home field belongs to the design branch `feat/ask-roll-design-system` (another session). |
| Words in images: OCR + keyword index + word bonus (DigUp 2) | L3 | Screenshots (2,532) and Vision's `isUtility` images (3,821) are Roll's text-heavy categories; gate OCR to them to limit heat (indexing was thermal-bound: 62 % `serious`). |
| Similar shots too loose (handoff §2) | L4 | Founder chose "same moment + scene". |
| Blurry is mostly videos (handoff §3) | L4 | Founder chose blurry photos only. |
| Test set of queries for piles (DigUp 5) | L5 | Proxy labels from metadata the library already has (screenshot subtype, media type, `isUtility`, `sensitive`, blur) give ground truth without hand-labelling; tunes L2's numbers. |
| Same build number skips "Preparing search"; 19,512 unknown file types; empty index-run churn (handoff §4) | L5 | Small, independent. |
| More than one frame per video (DigUp 4) | **dropped** | 5,183 of 5,190 videos on the founder's phone were indexed from the local preview (`asset.source = 'preview'`); more frames need the iCloud original (36.8 GB). Revisit only for local videos. |
| Audio (DigUp 6) | **dropped** | Large job, little value for a photo cleaner. |

## Lanes (one worktree and one branch each; I integrate into `feat/search-and-piles`)

**Shared contract (L2 ↔ L3).** L2's typed search takes keyword coverage as a closure, so Ranking doesn't need a
protocol in Store: `keywordCoverage: @Sendable ([String]) async throws -> [String: Double]`, asset id → share of the
query's terms found in that asset's text (0…1). L3 provides `Repositories.keywordCoverage(terms:)` with exactly that
signature. Terms are lowercased, diacritics folded, words of ≥ 2 letters; L2 owns tokenizing (`SearchTerms.terms(_:)`),
L3 calls it the same way when indexing (copy the 10-line function if needed; L2's is the one kept at integration).

**File ownership (to keep merges clean).**

| Lane | Owns | Must not edit |
|---|---|---|
| L1 search speed | `Store/VectorStore.swift`, `Store/Repositories+Ranking.swift`, the pool + dot section of `Ranking/SwipefileEngine.swift`, `App/QA/QASearchBench.swift` | Scorer, Presets, Dedupe, Indexer, Schema |
| L2 scale, fold, typed query | new `Ranking/QueryScale.swift`, `Ranking/SearchTerms.swift`, `Ranking/LibrarySearch.swift` (+ tests) | `SwipefileEngine.swift` (wiring happens at integration), Store |
| L3 OCR + keywords | new `Signals/TextRecognition.swift`, `Store/Schema.swift` (migration **v10** only), new `Store/Repositories+Text.swift`, `Indexer/Indexer.swift` | Ranking |
| L4 Similar + Blurry | `Dedupe/*`, `Ranking/Presets.swift` (Blurry only), `Store/RankingAsset.swift` (`CandidateFilter`), `Ranking/SwipeDeck.swift`, `Overview/*` | VectorStore, Indexer |
| L5 eval + small fixes | new `scripts/eval/` (+ `evals/piles.json`), `App/AppModel.swift` (prepare marker), investigation notes | RollCore sources owned above (report a fix instead) |

**Rules for every lane.** TDD with Swift Testing (failing test first). Evidence, not guesses: every number names its
evidence file; one variable per experiment. Private data (`~/egcm-evidence-raw/`, photo ids) never enters the repo.
The global pre-commit hook blocks staged files over ~5k tokens (bytes/4): split big files. Don't run `xcodebuild` /
`just build` (disk: ~13 GB free; I compile-check App code at integration). RollCore tests: `cd Packages/RollCore &&
ROLL_GEMMA_PATH=<path to embeddinggemma-coreml>/swift swift test` (a worktree's relative sibling
path doesn't resolve). Remove `Packages/RollCore/.build` when done. Commit on the lane branch with the attribution
line; don't push, don't merge.

## Integration (me)

1. Merge L4, L5, L3, L1, then L2; wire `QueryScale` + fold into `SwipefileEngine.candidates` (untrained piles) and
   expose `LibrarySearch` with L3's `keywordCoverage`; set the z gate and fold ratio from L5's eval.
2. `swift test` (all), `just build`, `just release-check`.
3. Phone: install over the proof build (data kept; the prepare-marker fix makes it prepare once, ~17 min), run
   `-QAMetrics -QASearchBench`, and record step timings and pile/typed-query times against the goals in
   `docs/investigations/2026-10-29-search-and-piles-results.md`.
