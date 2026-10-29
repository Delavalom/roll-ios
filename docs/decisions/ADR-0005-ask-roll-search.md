# ADR-0005: Ask Roll search and what its answers may say

**Status:** accepted, 2026-10-28

## Context

Home is now Ask Roll. You describe a pile ("screenshots of group chats"), see what matches, narrow it down, swipe
through it, and apply. It is a conversation, but nothing in it is generated. The prototype is
`docs/design/ask-roll/prototype.html`.

Two problems:

- **Which photos match a sentence.** Text-to-image cosines from EmbeddingGemma are small, and their level shifts
  from query to query. A single absolute floor either misses a clear standout or floods a vague query.
- **What an answer may claim.** A chat interface invites fake "thinking", made-up confidence, and generated prose.

## Decision

**Matching** (`PhotoSearch.rank`, called by `SwipefileEngine.search` over the whole live index):

- **What qualifies.** A photo qualifies if either:
  - its cosine clears `SwipefileEngine.untrainedFloor` (0.2, the floor custom piles already use), or
  - it stands out from this query's own library distribution: a robust z-score (median and MAD) of at least 4.
- **Guards on the z-score.** The z path is off under 50 photos. The spread is never taken as less than 0.01, so
  near-identical scores can't produce standouts.
- **Weaker matches.** Qualified photos under half the way from the library median to the best score are *weaker*.
  The answer folds them ("6 weaker matches folded") rather than dropping them.
- **Refinements.** Refinements ("Older than a year", "Biggest first", "Only on this iPhone") filter or reorder
  what matched. They never change the statistics. Undated photos are never "older than a year".

The thresholds are first guesses and are not tuned on real libraries yet. Retune them in `PhotoSearch` with
measurements from devices.

**Swiping an answer** uses `SearchDeck`:

- It deals the matches in the answer's order, minus anything decided or deleted.
- Swipes, undo, and "looks done" go through the engine, so they're stored and train the pile like any other.
- The pile is a delete pile with the query as its only prompt, made once per query. A user's own pile is never
  reused.

**What answers may say.** Every sentence is built from data:

- **Status line.** "Compared 29,589 items on this iPhone in 0.09 s" is the engine's count and its own measured
  time: query embedding, the store read, `dotAll`, and ranking. There are no staged delays.
- **The reply.** It comes from `SearchSummary`: the shortest run of at most three half-years holding 60% of *all*
  the matches, counting undated ones, plus a favorites count. It says nothing when too few matches have a date.
- **The swipe sticker.** It reports what happened in this session ("7 of the last 10 on target", "3 swipes so
  far"). It says it learns only when the deck trains the pile, so not on the signal deck or size-ranked piles.
- **Sizes and claims.** Sizes are "about" (ADR-0002). The app says "on-device AI", not "Neural Engine": which
  compute units Core ML uses isn't something the app checks.

## Consequences

The answer is honest, but it can be blunt: a vague query on a small library says "Nothing stood out". The demo
video and App Store copy may name EmbeddingGemma 2 and the Neural Engine only with a measurement taken on a real
iPhone. The 0.09 s in the prototype is a placeholder until then.

## Amendment 2026-10-29: retuned on the founder's library

Measured on the founder's real index (29,681 vectors; `docs/investigations/2026-10-29-pile-eval.md`): with
EmbeddingGemma 2 every photo's cosine cleared the 0.2 floor for every query (cosines average 0.58–0.66), so the
first rule above matched the whole library. Now:

- **What qualifies:** a photo stands out on this query's own scale over the whole library, z = (cosine − mean) /
  deviation ≥ 2.0 (`QueryScale.zGate`, the eval's choice), **or** its text holds at least half of the query's words
  (`LibrarySearch.coverageGate`; text from Vision OCR of screenshots and documents, schema v10). No cosine floor,
  except as the fallback for a library too small or flat for a scale (`QueryScale.isDegenerate`).
- **Order:** `LibrarySearch.fusedScore` (z plus a word bonus; lookups such as codes weigh words more).
- **Weaker:** under 0.4 × the best fused score (`Fold.defaultRatio`; 0.5 folded 35 % of true matches, close to a
  random cut).
- **Speed:** the search uses the piles' in-memory rows and one matrix product, and reads only the qualified photos'
  fields (`Repositories.searchAssets(ids:)`).

Still open: an honest "Nothing stood out" for nonsense queries. They pass the z gate about as often as real ones;
the best cosine separated them in the eval by under 0.01, too thin to ship.
