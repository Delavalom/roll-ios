# ADR-0006: Find search (what `FindConfig.shipping` turns on, and why)

**Status:** accepted pending founder review, 2026-11-15. Supersedes the parts of ADR-0005's 2026-10-29 amendment
that describe how Find answers are cut and ordered; Ask Roll's `SwipefileEngine.search` (V0) is unchanged.

## Context

Plan `docs/superpowers/plans/2026-11-15-find.md` added typed-search variants to RollCore (`FindSearch`, V1–V5 and a
nothing-found test) and a judged eval on the founder's library (49 queries: activities, events, places and trips,
things, album-derived queries, nonsense; pooled TREC-style judging; private data outside the repo). Round 2, P@20
over all queries:

| Variant | P@20 | Note |
|---|---|---|
| V0 today | .823 | median answer 676 photos |
| C60 (V0 + keep scores >= 0.6 × best) | .823 | median answer 130 |
| V4 Vision tags fused like words | .841 | things .69 → .72, events .85 → .90 |
| V5 "more like these" seeds | .837 | |
| V3 events as a ranking bonus | .793 | worse |
| V2 query understanding | .674 | two bugs, below |

V2's losses had two causes:

- Holiday words were removed from the embedded text, so "christmas 2023" became "everything 24–26 December 2023,
  by time": P@20 0.2 although all 34 relevant photos were among its 98 results.
- Place words were a hard filter. Only 18.6 % of the library has a location (WhatsApp saves never do), so trip
  albums (a city trip, a country trip) fell from P@20 .80 (meaning alone) to .48.

Tags cost ~1.4 s per query over 30k photos because every photo's labels were folded again on each query.

## Decision

`FindConfig.shipping` (Ask answers, "more like these", living albums):

- **Ranking V0** (z on the query's own scale, words fused, weaker folded at 0.4).
- **`relativeCut` 0.6**: same P@20 as V0, answers about five times smaller (median 130).
- **Nothing found** when the best cosine is under 0.735; the app shows the closest few instead.
- **Understanding on, fixed.** Holiday words filter by their days and stay in the embedded text
  (`keepHolidayWords`). Months, seasons, years and relative dates filter and leave it, as before. **Places are soft**
  (`PlaceMode.soft`, the default): photos located elsewhere are dropped, photos located there get a z bonus
  (`placeBonus` 1, a first guess), photos without a location stay and compete on meaning at the normal gate, and
  place words stay in the embedded text. The hard filter remains available (`PlaceMode.hard`).
- **Tags on, as evaluated**: `VNClassifyImageRequest` labels with confidence >= 0.3 (stored from 0.1, top 10, on a
  ~360 px local image), `tagWeight` 1, `tagGate` 0.5. A post-index tag pass (`TagIndexer`, Schema v12 `assetTag`)
  fills them after the text pass, thermal-gated and resumable; search folds them once per tag write into an inverted
  index (`TagIndex`), not per query.
- **Events group, never rank**: sections by moment and "rest of this event" (`groupByEvent`, `expandRest`), support
  weight 0.

Round 3 of the eval (`find-eval`, variants V2s, V24s and SHIP; 2026-11-15, before judging the ~5 new results it
brought into the top 20) measured, P@20 overall: V0 .823, V4 .841, V2s .782, V24s .799, SHIP .797 (median answer 61,
9 of 12 nonsense queries refused, no real query refused). Album trip queries: V2s .800, as V0 (round 2's V2: .48).
"christmas 2023" with its dates enforced: V2s .85 (round 2's V2 .2, V0 0). What still costs SHIP against V4: the
scorer judges dated queries on their subject only ("beach last summer": V0 1.0, but 2 of its 83 relevant photos are
from last summer), and "halloween costume" falls from .55 to 0 because the holiday filter keeps only 31 October to
1 November while most costume photos are from other days.

## Consequences

- Every photo gets one Vision classification after indexing (on the phone at utility priority, paused from thermal
  `.fair`); until the pass reaches a photo it has no tags and ranks on meaning and words alone.
- A query naming a place no longer hides unlocated photos, so the answer notes about "no location" only appear in
  hard mode.
- `placeBonus` and the 0.735 refusal floor are first guesses checked by one library; retune them with more judged
  libraries before trusting them further.
