# Results: fast search, honest piles, words in images (2026-10-29)

Plan: `docs/superpowers/plans/2026-10-29-search-and-piles.md`. Branch `feat/search-and-piles` (lanes L1–L5 merged,
then wired). Each lane's measurements and reasoning are in its own note; this page is the summary and the phone check.

| Lane | Note | Evidence |
|---|---|---|
| L1 search speed | `2026-10-29-search-speed.md` | `evidence/2026-10-29-search-speed/` |
| L2 query scale, folding, typed search | API docs in `Ranking/QueryScale.swift`, `LibrarySearch.swift` | tests |
| L3 words in images | `2026-10-29-ocr.md` | `evidence/2026-10-29-ocr/` |
| L4 Similar + Blurry | `2026-10-29-similar-blurry.md` | `evidence/2026-10-29-similar/` |
| L5 pile eval + small fixes | `2026-10-29-pile-eval.md`, `2026-10-29-small-fixes.md` | `evidence/2026-10-29-pile-eval/` |

## Mac results (before the phone)

- **Search** (29,681 vectors x 256, Mac bench, median of 5 warm runs; `mac-before.json` → `mac-after.json`): a
  3-prompt pile 413.9 → 15.4 ms in Debug (82.6 → 3.0 ms Release); Screenshots (1 prompt, filtered) 132.1 → 10.1 ms
  Debug. The cost was one full sorted search per prompt, not the SQL read the handoff suspected. Fixes: one
  `VectorIndex.dotAll` matrix product, candidate rows kept in memory until a ranking-relevant write, integer rows.
  First search after such a write: ~100 ms Debug (41 ms Release) while the rows are read again.
- **Piles on each query's scale** (pile eval over the founder's real index, proxy labels; `pile-eval` evidence):
  the old 0.2 cosine floor passed every vector for every query (cosines average 0.58–0.66). Untrained piles now
  deal only z >= 2.0 (mean precision 0.32, recall 0.30 over 17 labelled queries, ~956 results each) and flag cards
  under 0.4 x the pile's best z as weaker matches (folds 14 % of true matches, the less precise ones).
- **Similar shots** (the founder's database): no chaining; 13,060 members / largest group 175 → 9,636 / largest 35
  (p95 8). Duplicates rise 1,315 → 3,219 members: exact copies the old chains had swallowed.
- **Blurry**: 2,877 items (40.27 GB, mostly videos) → 67 photos (0.32 GB).
- **Words in images**: Vision `.accurate` at 960 px, no language correction: 264 ms median per image on the Mac,
  93 % of words found (`.fast` found 12–21 %). Gated to screenshots + `isUtility` (~6.3k of 24.5k images here).
  Keyword lookup over 6.3k texts: 1–24 ms.
- **Small fixes**: the prepare marker now includes the data container (no more 52 s first search after a
  same-build install); the 11 empty index runs were the file-type lookup batches going round the loop (fixed);
  the 19,512 "unknown" file types are rows that never needed a lookup (QA stats wording, not a bug).
- **Dropped with reasons**: more than one frame per video (5,183 of 5,190 videos were indexed from the local
  preview; frames need the iCloud original), audio.

Tests: 894 RollCore tests pass (after the merge of `main`); `just build` and `just release-check` pass.

## Open

- **Honest "nothing found"** isn't solved by the z gate: nonsense queries pass about as often as real ones. In the
  eval, each query's best cosine separated them (nonsense 0.694–0.741, real 0.740–0.820), a margin under 0.01, so
  it isn't wired; it needs a bigger set of nonsense and absent-thing queries first.
- Similar: 14 % of grouped members are saved batches sharing one timestamp (chat saves), not shots taken again.
  The founder decides whether those count as one moment.
- The public site (`site/src/pages/index.html`) still says "blurry shots" (needs a site deploy).

## Ask Roll (merged from `main` during integration)

`main` gained Ask Roll and the design system (another session) while the lanes ran. Its `PhotoSearch` admitted
any photo with cosine >= 0.2 or a robust z >= 4; on this library the first rule matches every photo for every
query. At the merge it moved to the lanes' rules (ADR-0005 amendment): z >= 2 on the query's own scale or half the
query's words in the photo's OCR text, fused order, fold at 0.4, on the piles' fast path (`SwipefileEngine.search`
reads only the qualified photos' fields). One typed-search path: `LibrarySearch` keeps the fusion rule.

## Phone (iPhone 13 Pro Max, install over the proof build, data kept)

Build `814ad93` (Debug, `-QAMetrics -QASearchBench`), launched 14:05:41 AST, charging, 4.4 GB free. Evidence:
`evidence/2026-10-29-search-and-piles-phone/` (`summary.json`, `search.jsonl`, `timeline.jsonl`, `home.json`; regenerate
with `extract.py`).

**Search: both goals met.**

| Preset | Pool | First open (ms) | Warm median, attempts 2–5 (ms) | Proof (ms) |
|---|---|---|---|---|
| Receipts (3 prompts) | 29,682 | 117.0 | 14.5 | 297–318 |
| Private stuff | 29,682 | 50.9 | 14.5 | 297–318 |
| Memes | 24,496 | 46.8 | 14.1 | 297–318 |
| Screenshots | 2,532 | 8.3 | 8.2 | 103–105 |
| Blurry | 67 | 7.9 | 7.8 | — |

- Warm piles take 7.8–14.5 ms (goal < 50 ms); the slowest warm attempt is 16.8 ms. `sql_ms` is 0 for every attempt,
  including each preset's first: the post-drain warm-up (`preparePools`) did its job.
- The first open of a pile is over 50 ms only for the very first one (Receipts, 117 ms): embedding its 3 prompts
  (50 ms, cached afterwards), building its pool (20 ms) and a cold first matrix product (35 ms; 8–10 ms after). The
  other presets' first opens are 47–51 ms, mostly embedding their prompts (21–25 ms) and pool (10 ms).
- Typed search (Ask Roll's path, 8 fixed bench queries x 5): warm median 23.7–29.4 ms, first 25.7–41.1 ms, the query
  embedding included (goal < 100 ms).
- The phone's `dot` is ~8 ms per search in Debug (Mac Debug ~11 ms); `score` 5–6 ms over a full pool.

**Ask Roll results are large and don't say "nothing".** Each typed query qualifies 434–1,623 strong matches plus up to
481 weaker ones (3–5 % of the library): z >= 2 on one query's scale passes the tail of every distribution. The nonsense
query (`xkqzv plorb`) got 890 matches, as many as real ones (the open item above). No result came from words yet
(`byWords` 0; see the text pass below).

**Home on the phone matches the Mac.** Similar 3,007 groups / 9,636 members / largest 35; duplicates 1,503 groups /
3,219 members / largest 12; Blurry 67 photos (0.32 GB).

**Model and device.** Preparing the model took 21.1 min (proof: 17.2). The phone was `fair` from 37 s and `serious` for
most of the run, while charging and with the text pass waiting. Memory peaked at 1,618.7 MB while preparing (under
the 2,100 MB compile limit) and was 225 MB during the bench. Sync read 49.9 s; the photo pass had 1 new item.

**Text pass: 483 of 5,198 candidates read; the rest are in iCloud.** It started after the first drain (64 s) and
waited: it pauses while the phone is `fair` or warmer (`TextIndexer.defaultThermal`), and the phone only reached
`nominal` at 25.2 min. It then finished at 27.7 min: 483 images read (461 with words, 0 failed) and 4,715 recorded
unread, so about 0.3 s per image at most, unread checks included. Unread means no local image at 960 px: this library is
~99.95 % in iCloud (84 MB of 170.5 GB on the device), and the local pass doesn't download. The rest wait for the opt-in
iCloud upgrade (Wi-Fi + charging), which reads text after a finished upgrade. The typed bench ran before the pass, so
no result was found by its words here.

- The thermal gate is right for battery and heat, but on a busy, charging phone it held words back for 25 min.
- On an iCloud-heavy library, words-in-images helps ~9 % of its candidates until the upgrade has run. It isn't a
  default-path feature for such a library.
