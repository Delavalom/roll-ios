# Ad scripts for Roll 1.1: one per problem (DRAFT, 2026-11-16)

Scripts for the concepts in `docs/marketing/find-positioning.md` §3, rewritten for what 1.1 ships. **Nothing here runs
or spends without the founder's OK.** Rules for every script: `PRODUCT_GUARDRAILS.md`, ADR-0002 (no performance
claims; sizes "about"), ADR-0005 (say "on-device AI", never "Neural Engine" until measured), no memory videos (off in
Release), no automatic adds or deletes, no competitor names, no other companies' prices.

**Footage rule (changed from the positioning doc).** Screen footage comes from the Roll-Demo simulator's demo library
(200 CC0 fixtures + the CC0 Lisbon trip from `scripts/make_demo_trip.py`), never the founder's photos, asset ids,
album titles or places. Any on-screen number is the one the demo library's own screen shows. A UGC creator may film
their own phone and library, with written consent, and only their numbers appear. Simulator footage carries a small
"Demo library" super.

**Numbers an ad may say** (only with the condition): answers in 35–46 ms warm on an iPhone 13 Pro Max (Debug build);
median answer 69 photos instead of 676 (one 30k-photo library); "christmas 2023": 22 of 47 found, 19 of the top 20
right. Safer in ads: no number at all. Never "in seconds", "any photo" or "every photo you've ever taken".

CTA default: "Search and albums are free. Your first 50 cleanups are free. Then pay once."

## 1. "I can't find the trip" (Find, flagship; concept #1)

Audience: trip group, 20–35. Format: screen recording + text supers, 15 s and 6 s cuts. Source: the 1.1 demo video's
Find segment.

| Time | Picture | Super / VO |
|---|---|---|
| 0–2 s | Camera roll scrolling fast, endless grid | "Send me the pics from Lisbon" |
| 2–5 s | Roll: type "Lisbon 2024", letter by letter | "Type the trip." |
| 5–9 s | Answer grouped by day: "Lisbon · 10 May, 2024", "Buraca · 11 May, 2024", "Lisbon · 12 May, 2024" (29 photos in the demo library) | "Roll finds it, day by day." |
| 9–12 s | Make album → grid → Create → "Added 29 photos to “Lisbon 2024”" | "Make the album." |
| 12–15 s | End card: app icon, "Clear space. Find your photos." | "Albums are free. On your iPhone. Nothing uploaded." |

6 s cut: 2–5 s + 9–12 s + end card. Don't say how long it took unless the clip shows the status line's real time.

## 2. "One album for every game" (Find, living album; concept #2)

Audience: weekly activity. Format: UGC (creator's own library, with consent) or SR. Held until a demo library has a
weekly activity; the CC0 set doesn't yet.

| Picture | Super / VO |
|---|---|
| Phone, Saturday game photos | "Every Saturday, 40 new soccer photos." |
| Make album "Soccer" → Keep this album updated | "Make the album once." |
| A week later: Home shows "8 new photos for Soccer" → tap Add | "Roll finds the new ones. You say yes." |
| End card | "Nothing is added until you tap." |

Never "updates itself" or "automatic": the album only offers.

## 3. "Storage almost full" (Clear; concept #3)

Audience: storage full. Format: SR, 15 s. Number = what the recorded library's screen shows, "about".

| Picture | Super / VO |
|---|---|
| "iPhone Storage Almost Full" banner | "Before you pay for more storage" |
| Roll's scan → "Free about {X} on this iPhone" | "See what you don't need." |
| A pile (Blurry in the demo library, which has no screenshots), swipe left, keep, left | "Swipe. Keep or let go." |
| Review & apply → iOS confirmation | "You decide. Deleted items wait 30 days in Recently Deleted." |
| End card | "Get your space back without uploading your photos." |

## 4. "Where's that receipt?" (Find, words; concept #4)

Audience: admin keeper. Format: SR or static, 10 s.

| Picture | Super / VO |
|---|---|
| "Need the receipt from March?" | Hook |
| Type "receipt" → receipts pile; add "March" | "Describe it. Roll reads the words in your screenshots too." |
| Tap the receipt → share | "Find it" |

Only with a demo receipt dated in March in the demo library (the CC0 fixtures have receipts; date one when building).

## 5. "2,532 screenshots" (Clear; concept #5)

Audience: screenshot hoarder. Format: UGC. The number must be the creator's own on-screen count, never the founder's.

| Picture | Super / VO |
|---|---|
| Creator: "I have {N} screenshots." | Hook, their number |
| Type "screenshots of group chats" → pile → swipe | "Say what you don't need. Swipe." |
| Apply → iOS asks → Delete | "Gone. Or back from Recently Deleted for 30 days." |

## 6. "Nothing leaves your iPhone" (privacy, both stories; concept #6)

Audience: privacy-minded, local-AI crowd (also the r/LocalLLaMA clip). Format: SR, 12 s.

| Picture | Super / VO |
|---|---|
| Control Center: Airplane Mode on | "Airplane mode." |
| Type "Lisbon 2024" → the trip, grouped by day | "Still finds the trip." |
| Ask Roll status line (its real time) | "On-device AI. Place names from a list inside the app." |
| End card | "Nothing leaves your iPhone. Not even your search." |

## 7. "Pick three" (Find, more like these; concept #7)

Audience: creator, trip group. Format: SR. Pick three sunset/viewpoint photos in the Lisbon answer → More like these →
the rest. Line: "Pick a few. Roll finds the rest."

## 8. "Same box" (both; concept #8)

Audience: parent, broad. Format: static carousel. Card 1: "Delete these" → "blurry photos" pile. Card 2: "Keep these"
→ "Lisbon 2024" made into an album. Card 3: "Same box. Clear what you don't want, find what you do."

## Held

- **#9 "14 shots of the same sunset"**: needs similar shots inside the demo trip; the Lisbon set has a few pairs (005/006,
  012/013) but not a burst. Build when there is one.
- **#10 birthdays/kids**: don't run until event P@10 on more libraries is measured (positioning risk 6).
