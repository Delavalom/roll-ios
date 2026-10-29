# Similar shots and Blurry on the founder's library (2026-10-29, lane L4)

Founder decisions (plan `docs/superpowers/plans/2026-10-29-search-and-piles.md`): **Similar shots = same moment +
same scene**, every member close to the group's first shot within a short span, no transitive chaining. **Blurry =
`blur < 25`, photos only**; a low aesthetic score no longer counts; no "Low quality" pile.

**Data.** The founder's database after the 29,685-item index (handoff §2–3), read only. **Tool.** An env-gated Mac
test in RollCore, `Tests/OverviewTests/Evidence/` (never part of the app): it copies the database to a temporary
folder, opens the copy with the app's `AppDatabase`/`Repositories`, decodes prints with `FeaturePrints.decode` and
compares them with `Print.distance` (the squared distance the app uses), and writes identifier-free JSON:

```
cd Packages/RollCore && ROLL_EVIDENCE_DB=<roll.sqlite> ROLL_EVIDENCE_OUT=<folder> ROLL_EVIDENCE_PHASE=after \
  ROLL_GEMMA_PATH=<egcm>/swift swift test --filter 'SimilarEvidenceTests|BlurryEvidenceTests'
```

Evidence (all in `docs/investigations/evidence/2026-10-29-similar/`): `similar-distances.json` (§1–2),
`similar-rules-1…4.json` (§3), `similar-current-code-before.json` / `-after.json` (the code at e48da12 and on this
branch), `blurry-before.json` / `blurry-after.json` (§5). Rows grouped: 29,669 (`groupable`, ≥ 288 px).

The tool's copy of the old rule reproduces the shipped `DuplicateGrouper` exactly (`equalsOldUnionFind: true` in the
before file), and the new `DuplicateGrouper` equals the tool's star rule with the shipped constants on all 29,669 rows
(`equalsAnchorWithShippedConstants: true` in the after file).

## 1. Why Similar held 44 % of the library

The old rule linked a pair inside a 120 s / 24-neighbour window when the print distance was < 0.35 or the hashes were
≤ 4 bits apart, then took connected components. In the five biggest groups every link is under 0.35, but most of the
group is not (`similar-distances.json`, `oldLargestGroups`):

| Members | Time span | Linked pairs p50 / p90 | All member pairs p50 | Pairs ≥ 0.35 | Distance to first shot p50 |
|---|---|---|---|---|---|
| 175 | 14,071 s (3.9 h) | 0.215 / 0.324 | 0.339 | 47 % | 0.414 |
| 141 | 3,603 s | 0.262 / 0.335 | 0.571 | 84 % | 0.494 |
| 112 | 2,208 s | 0.244 / 0.328 | 0.563 | 77 % | 0.805 |
| 95 | 124 s | 0.264 / 0.337 | 0.467 | 77 % | 0.808 |
| 74 | 2,972 s | 0.221 / 0.333 | 0.464 | 73 % | 0.402 |

So the handoff's hypothesis holds: chains of loosely alike neighbours, merged transitively, run for hours. A threshold
alone doesn't fix it: union-find at 0.25 still makes a 136-member group (§3).

## 2. What the distances look like here

Pairs the old window compared (111,645; `windowPairs`): no valley to cut at; the histogram rises smoothly from 0 to a
peak at 0.6–0.8.

| Pairs | n | p10 | p50 | p90 | p99 |
|---|---|---|---|---|---|
| hashes ≤ 4 bits apart (surely one scene) | 2,471 | 0.000 | 0.026 | 0.088 | 0.304 |
| same timestamp (saved in one go) | 12,368 | 0.078 | 0.339 | 0.903 | 1.387 |
| non-screenshot photos 0–2 s apart | 29,438 | 0.119 | 0.452 | 1.001 | 1.406 |
| non-screenshot photos 30–120 s apart | 18,489 | 0.228 | 0.581 | 1.190 | 1.645 |

## 3. Candidate rules

Star linkage ("anchor"): each unclaimed shot, in time order, claims later unclaimed shots of its media type within the
span whose print is under t from **its own** (or hash ≤ 4 bits from its own), examining at most `cap` unclaimed
successors. Bursts and the exact-hash pass come first ("exactLast": exact pass after the moments). Similar shots
columns, then Duplicates (`similar-rules-*.json`):

| Rule | Groups | Members | Extras | Largest | p95 | ≥ 10 | % library | Extras GB | To first shot p50/p90 | Widest pair p50/p90 | Span p50/p90 s | Dup. groups / members / largest |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| union-find 0.35 120 s (old) | 2,835 | 13,060 | 10,225 | 175 | 12 | 223 | 44.0 | 44.99 | 0.256 / 0.489 | 0.258 / 0.475 | 4 / 87 | 593 / 1,315 / 9 |
| union-find 0.30 | 2,758 | 12,059 | 9,301 | 169 | 11 | 191 | 40.6 | 41.15 | 0.219 / 0.412 | 0.225 / 0.415 | 4 / 83 | 674 / 1,496 / 9 |
| union-find 0.25 | 2,652 | 10,884 | 8,232 | 136 | 10 | 161 | 36.7 | 36.01 | 0.183 / 0.338 | 0.191 / 0.341 | 3 / 72 | 749 / 1,665 / 9 |
| anchor 0.35 60 s | 3,131 | 10,480 | 7,349 | 35 | 8 | 85 | 35.3 | 29.90 | 0.201 / 0.322 | 0.248 / 0.359 | 3 / 33 | 1,472 / 3,154 / 12 |
| **anchor 0.30 60 s cap 64** | **3,007** | **9,636** | **6,629** | **35** | **8** | **64** | **32.5** | **26.85** | **0.178 / 0.277** | **0.215 / 0.306** | **3 / 30** | **1,503 / 3,219 / 12** |
| anchor 0.30 120 s | 3,028 | 9,840 | 6,812 | 35 | 8 | 72 | 33.1 | 28.16 | 0.181 / 0.278 | 0.219 / 0.313 | 3 / 46 | 1,503 / 3,219 / 12 |
| anchor 0.30 30 s | 2,993 | 9,381 | 6,388 | 35 | 7 | 54 | 31.6 | 25.73 | 0.173 / 0.276 | 0.209 / 0.299 | 2.5 / 20 | 1,500 / 3,210 / 12 |
| anchor 0.30 60 s cap 24 | 3,009 | 9,626 | 6,617 | 25 | 8 | 67 | 32.4 | 26.83 | 0.177 / 0.277 | 0.215 / 0.306 | 3 / 29 | 1,501 / 3,215 / 12 |
| anchor 0.30 60 s exactLast | 3,311 | 11,268 | 7,957 | 48 | 8 | 103 | 38.0 | 34.43 | 0.177 / 0.277 | 0.217 / 0.308 | 3 / 31 | 750 / 1,627 / 9 |
| anchor 0.25 60 s | 2,831 | 8,668 | 5,837 | 35 | 7 | 39 | 29.2 | 23.30 | 0.154 / 0.232 | 0.183 / 0.250 | 2 / 26 | 1,539 / 3,291 / 12 |
| anchor 0.20 60 s | 2,543 | 7,376 | 4,833 | 30 | 6 | 26 | 24.8 | 19.22 | 0.131 / 0.186 | 0.151 / 0.199 | 2 / 23 | 1,609 / 3,439 / 12 |

(Anchor rows use cap 64 unless noted. "Widest pair" is over groups of ≤ 60 members. 120 s variants of 0.35/0.25/0.20
are in the files: each adds 1–2 % members over its 60 s row.)

## 4. Chosen: star linkage, t = 0.30, 60 s from the first shot, 64 neighbours, exact copies first

- **Star, not union-find.** It is the founder's definition and the only change that removes the chains: largest group
  175 → 35, groups of 10+ 223 → 64, and by construction every member is under 0.30 from its group's first shot (widest
  pair p90 0.306, was 0.475). Test: `aChainOfLookAlikesIsNotOneGroup` (A~B~C with A and C far apart).
- **t = 0.30.** Just above the p99 of near-identical pairs (0.304), so frames of one scene that hash alike also link by
  print; below the median of same-timestamp pairs (0.339), which are mostly batches saved from chats. 0.35 adds 844
  members that are 0.30–0.35 from their first shot; 0.25 drops 968 more. Nobody has looked at samples yet, so this is
  the middle of the measured range and one constant (`DuplicateGrouper.fpThreshold`) to move after the founder's look.
- **60 s.** "A short span": 120 s adds 204 members and doubles the p90 span (46 s vs 30 s); 30 s drops 255.
- **Cap 64.** With 24, 398 anchors hit the cap and the largest group was the cap (25): real bursts were cut. 64 leaves
  22 cap hits for 40,050 print comparisons (old rule: 111,645 pairs in its window). Mac debug run: 2.3–4.4 s (old 5.4 s).
- **Exact copies first** keeps the exact-hash pass as it was (a bucket of ≤ 8 same-hash shots is a group outright).
  It finds 1,276 exact-hash groups, and Duplicates members sit p90 0.048 from their first shot: real copies. The old rule
  had 428 such groups: it swallowed the rest into Similar chains. Doing moments first (exactLast) keeps Duplicates
  near its old size but leaves 86 copies in no group and puts copies among Similar picks, so no.

The data does change Duplicates: copies the chains hid now show there.

| Home (this database) | Before (e48da12) | After |
|---|---|---|
| Similar shots | 10,225 extra, 2,835 groups, 13,060 members (44.0 %), largest 175, 44.99 GB | 6,629 extra, 3,007 groups, 9,636 members (32.5 %), largest 35, p95 8, 26.85 GB |
| Duplicates | 722 extra, 593 groups, 1,315 members, largest 9, 3.91 GB | 1,716 extra, 1,503 groups, 3,219 members, largest 12, 9.76 GB |
| Blurry | 2,877, 40.27 GB | 67, 0.32 GB |
| Freeable | 87.25 GB (the phone, proof §4) | 39.10 GB (`CleanupScanner` over the copy) |

Still open, for the founder's look: 32 % of the library is in a Similar group; 14 % of Similar members sit in groups
whose members all share one timestamp (saved batches, not moments shot again); screenshots are 3.6 % of members. If
saved batches shouldn't count as "one moment", that is the next rule to measure (e.g. leave one-timestamp groups out).

## 5. Blurry

`Preset.blurry.filter` is now `CandidateFilter(mediaType: image, blurBelow: AssetRecord.blurryBelow)`; the boost is
unchanged. SQL and Swift agree (`SignalDeckTests.blurryFilterAgreesInSQLAndSwift`, the Store's filter matrix, and on
this database: `presetNowSQLPool.sameIdsAsSwift: true`). SignalDeck, SwipefileEngine and CleanupScanner all read the
preset's filter, so the pile, its count and its bytes are photos only (`CleanupSummaryTests.blurryCountsPhotosOnly`,
`scannerCountsBlurryPhotosOnly`).

| (`blurry-before.json`, `blurry-after.json`) | Photos | Videos | Total |
|---|---|---|---|
| `blur < 25` | 67 (0.32 GB) | 55 (1.87 GB) | 122 |
| `aesthetic < -0.3` (trusted) | 1,133 (3.49 GB) | 1,736 (36.58 GB) | 2,869 |
| Blurry before: either | 1,139 (3.50 GB) | 1,738 (36.77 GB) | 2,877 (40.27 GB) |
| **Blurry after** | **67 (0.32 GB)** | **0** | **67 (0.32 GB)** |

The `previewSide >= 256` quality-trusted rule excludes none of them here: all 67 blurry photos were analysed from
300–320 px previews, and no `blur < 25` row of either type is untrusted. On-device bytes of the 67: about 0.

## 6. For the app and docs (not edited in this lane)

- `App/Features/Swipefiles/SwipefileListModel.swift:87`: "Out of focus and badly exposed shots" is no longer true
  (no exposure or aesthetic signal, no videos): e.g. "Out of focus photos".
- `App/Features/Home/HomeModel.swift:75`: unit "blurry shot(s)" could say "blurry photo(s)"; same for "blurry shots" in
  `PaywallView.swift:76` and `ModelStatusView.swift:9` if the wording should match.
- Similar shots now means "taken within a minute of the first and alike"; any explainer should say that. Duplicates
  roughly doubles on a library like this one (above), so copy or screenshots quoting counts will change.
- AGENTS.md map, Dedupe line: star linkage around each group's first shot (bursts, guarded exact-hash pass, then 60 s
  moments at print distance 0.30, 64 unclaimed neighbours), no union-find. The spec (`2026-10-22-roll-design.md`, the
  presets table at line 99 and "Grouping" at line 113) still describes the old Blurry filter and connected components.
