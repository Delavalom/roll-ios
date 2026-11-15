# Roll: Clear and Find (positioning, ads, App Store, launch) (DRAFT, 2026-11-15)

Lane A7 of `docs/superpowers/plans/2026-11-15-find.md`. **Draft for founder review. Nothing here is published,
uploaded to App Store Connect, posted or spent.** Rules that apply to every line: ADR-0002 (no performance claims;
sizes are "about"), ADR-0005 (say "on-device AI"; "Neural Engine" and model names only with a phone measurement),
`PRODUCT_GUARDRAILS.md`, and the outcome-first rule from `docs/learnings/2026-11-praktika.md` (L1).

Tags used below: **[today]** works in 1.0 as shipped. **[this session]** needs Find work landing now (place and date
words, answers grouped into trips, Make album, More like these, living albums). **[later]** memory videos (spike only).
**[eval]** needs a number from this session's find eval or the A8 phone check before it can be said.

## 1. Positioning

**One sentence:** Roll is the photo app that understands your library on your iPhone, so you can clear what you
don't want and find what you can't, just by describing it.

| | Clear (what Roll is known for) | Find (what people already use it for) |
|---|---|---|
| Problem | Storage full; 30k photos of screenshots, near-copies, blurry shots and big videos | The trip, the game, the receipt is in there somewhere, under 30k other photos |
| Moment | "Storage almost full" banner, before paying for more | Back from a trip, someone asks for the photos; making the recap video |
| Promise | Get your space back without uploading your photos | Type the trip and get the trip, ready to be an album |
| Proof | "Free about {X} on this iPhone" from your own scan **[today]** | "Puerto Rico 2024" returns the trip, grouped by day **[this session][eval]** |
| Ends with | Review & apply; deletes go to Recently Deleted for 30 days | An album in Photos, which you take to whatever video app you like |

**How they connect:** one engine reads every photo once, on the phone, and turns it into something it can compare to
your words. The same sentence box that finds "screenshots of group chats" to delete finds "beach last summer" to keep.
That is the line for anyone who asks why a cleaner does search: *Roll knows what's in your photos, so it can tell you
what to clear and find what you want to keep.*

Keep separate per audience: an ad sells one story. The product page and launch posts can carry both.

**Guardrail to update before any Find ad runs:** `PRODUCT_GUARDRAILS.md` opens "Roll is a photo cleanup tool". It
needs a founder edit to "clean up and find" with the new "does/doesn't" lines: Roll **offers** new matches for a
living album and never adds them on its own; place names come from an offline list, no network lookups.

## 2. Audiences

| Audience | Problem in their words | Message | Proof moment |
|---|---|---|---|
| Trip group (friends, couples, 20–35) | "Send me the pics from the trip" and they're mixed with 2 years of everything | Type the trip, get the trip, make the album | "Puerto Rico 2024" → the trip grouped by day → Make album **[this session]** |
| Weekly activity (soccer, gym, climbing, dance) | Wants one album of every game without scrolling for it each week | One album for every game, and Roll offers the new ones | Soccer album; next week Roll shows "8 new photos that look like Soccer", you tap Add **[this session][eval]** |
| Parent with ~40k photos | Phone full of kids' photos; can't find the birthday from two years ago; can't bear to delete randomly | Clear the junk around the kids, find each birthday in seconds | Clear: screenshots and near-copies "about X GB". Find: "birthday cake" grouped by year **[today: search; this session: grouping][eval]** |
| Storage full, about to pay for more | "Storage almost full" banner every week | Get your space back without uploading your photos | "Free about {X} on this iPhone" from the taste scan **[today]** |
| Admin keeper (receipts, IDs, notes) | The receipt from March for a return; a parking spot photo; a whiteboard | Describe it in plain words, Roll reads the words in your screenshots too | "receipt" finds it; "receipt March" narrows it **[today: words; this session: dates]** |
| Privacy-minded / local-AI crowd | Won't hand their library to a cloud service | It all runs on your iPhone; search works in airplane mode | Airplane mode on, search still answers; status line shows the measured time **[today]** |
| Screenshot hoarder (students, group-chat people) | Thousands of screenshots they'll never open | "screenshots of group chats" and swipe | Founder's library: 2,532 screenshots in one pile **[today]** |
| Creator / recap-video maker | Pulling 200 clips and photos for a recap takes an evening | Get the whole trip into one album, then cut it anywhere | Album ready in Photos; video app of their choice opens it **[this session]**; Roll-made reel **[later]** |

## 3. Ad concepts

Format key: UGC = a person on camera with the phone; SR = screen recording; Static = image or carousel. Every concept
uses a real library (the founder's or a consenting user's), never mock data. CTA default: "Search is free. Your first
50 changes are free. Then pay once."

| # | Story | Hook (first 2 s) | On-screen action | Line | CTA | Format | Audience | Needs |
|---|---|---|---|---|---|---|---|---|
| 1 | Find | Text over a beach clip: "every photo from Puerto Rico, one sentence" | Type "Puerto Rico 2024" → answer grouped by day → Make album → album opens in Photos | "Type the trip. Roll finds it." | "Make your trip album" | UGC + SR | Trip group | **[this session]**; a timed "in N seconds" hook only after A8 measures it **[eval]** |
| 2 | Find | "My soccer album updates itself. Almost." | Soccer album → a week later Roll shows new matches → tap Add | "Roll finds the new ones. You say yes." | "Start an album that keeps up" | UGC | Weekly activity | **[this session][eval]** |
| 3 | Clear | Storage-full banner, thumb hovers over "Buy more storage" | Open Roll → taste scan → "Free about {X} on this iPhone" → swipe → apply | "Get your space back without uploading your photos." | "See your number" | SR | Storage full | **[today]**; {X} = the recorded library's real number |
| 4 | Find | "Need the receipt from March?" | Type "receipt March" → the receipt → share | "Describe it. Roll reads your screenshots too." | "Find it" | SR / Static | Admin keeper | words **[today]**, "March" **[this session]** |
| 5 | Clear | "I have 2,532 screenshots." | "screenshots of group chats" → pile → swipe left, left, keep, left | "Say what you don't need. Swipe. Gone." | "Clear yours" | UGC | Screenshot hoarder | **[today]** |
| 6 | Both | Airplane mode toggled on | Search "dog at the beach" → results; status line shows the real time | "Nothing leaves your iPhone. Not even your search." | "Try it offline" | SR | Privacy / local AI | **[today]** |
| 7 | Find | Tap 3 sunset photos | More like these → a screen of sunsets from 5 years | "Pick three. Roll finds the rest." | "Try More like these" | SR | Creator, trip group | **[this session][eval]** |
| 8 | Both | Split screen: "Delete these" / "Keep these" | Left: "blurry photos" pile cleared. Right: "beach last summer" made into an album | "Same box. Clear what you don't want, find what you do." | "Do both" | Static carousel / SR | Parent, broad | Clear **[today]**, Find **[this session]** |
| 9 | Clear (inside Find) | "14 shots of the same sunset" | Find the trip → similar shots grouped → keep the best → album | "Keep the best one. Then make the album." | "Clean your trip" | SR | Trip group, creator | similar shots **[today]**, trip **[this session]** |
| 10 | Find | Parent voice: "Every birthday. Every year." | "birthday cake" → grouped by year → Make album | "Find each one in seconds, on your phone." | "Find yours" | UGC | Parent | **[this session][eval]**: do not run until P@10 for event queries is measured and good |

Run first (one per story, all honest today or this session): **#3** (Clear, today), **#1** (Find, flagship),
**#6** (privacy, today; also the r/LocalLLaMA clip).

Do not show: a push notification for living albums (unless one is built), any automatic add or delete, a Roll-made
video (memory videos are a spike), competitor apps by name, "boost/speed up/optimize". If a recap video app appears in
UGC, it is the user's own and unnamed in the line.

## 4. App Store

Live today (read-only `asc`, app 6826174715, 1.0 `READY_FOR_SALE`): name `Roll: Private AI Photo Cleaner`, subtitle
`Duplicates, blurs & big videos`, keywords
`storage,cleanup,duplicate,screenshot,blurry,compress,delete,swipe,gallery,space,organize,remover` (96 chars). The name
stays (ADR-0004): it carries "ai photo cleaner", and "ai" + "photo" already make "ai photo search" a one-word add.

**What factory-aso shows (US, 2026-11-15).** Roll isn't a tracked app in factory-aso, so there are no difficulty or rank
snapshots. Popularity below is `suggest_keywords`' quick estimate (5–100) from search hints; it is noisy (the same term
moved 42→46 and 54→74 between calls). Competition is read from the live top 10 (`search_app_store`, rating counts).

| Term | Popularity (est.) | Who ranks (ratings) | Read |
|---|---|---|---|
| ai photo search | 24 | New indie "AI Photo Search" apps with 0–7 ratings; reverse image search 41k, 12.9k | Low demand, weak field. Cheap: add `search` |
| ai photo finder | 26 (photo-finder 7) | n/a | Low. Add `finder` (also feeds "duplicate photo finder" 45) |
| photo search | not returned | Reverse image search (41k, 12.9k, 5.1k, 3.8k) and Google (5.4M) | Wrong intent (search the web by image). Don't chase in subtitle |
| find photos | not returned | Reverse image 41k, then 0–146 ratings | Weak field, unknown demand; "find" goes in subtitle |
| photo organizer | free photo organizer 30, ai photo organizer 18 | Cleaners: Cleanup 764k, Swipewipe 102k, Slidebox 16.7k; Google Photos 1.67M | Owned by cleaners and Google. Keep `organize` |
| photo album maker | 44 (album 24, smart albums 18) | Photo book printing: Shutterfly 605k, Chatbooks 250k, FreePrints 214k | Wrong intent (prints). Add `album` for long tail only |
| trip photos | trip 23 | Travel journals and maps, 0–7.3k | Low, mixed intent. Add `trip` for "trip album" long tail |
| search | 17 | n/a | Generic |
| **Cleanup, for comparison** | duplicate photo cleaner for iphone 79, duplicate photos remover 63, free storage cleaner for iphone 51, phone storage cleaner free 48, duplicate cleaner 45, photo cleaner free 32 | "photo cleaner": Cleanup 764k, Cleaner Kit 355k, Swipewipe 102k, Clever Cleaner 85k | 2–3× the demand of find terms, far stronger field |

**Conclusion:** people search the App Store for cleaners, not for photo search yet. So store search stays anchored on
Clear (where the demand is) and picks up the find terms through cheap single-word adds. Find is sold where it can be
*shown*: ads, social, and the first screenshot (conversion, not search). Ask the founder to approve tracking Roll in
factory-aso (`add_keywords`) to get real difficulty and rank; this lane did not add anything.

**Subtitle (≤30)**

| Option | Chars | Note |
|---|---|---|
| **Clear space. Find your photos.** | 29 | Recommended. Both stories, outcome words, adds `clear`, `find`, `space` to search. No overpromise |
| Free up space. Find any photo. | 30 | Stronger, but "any photo" promises recall the eval hasn't measured |
| Find the trip. Clear the rest. | 30 | Find-first; use once trips ship and the eval is good |
| Free up space. Upload nothing. | 30 | The Clear-only draft (`docs/aso/2026-11-outcome-first-draft.md`) |

**Promotional text (≤170, changes without a new version)**

- Now [today], 162: "Find any photo by describing it, and clear the ones you don't need. Roll's AI runs on your iPhone,
  so nothing is uploaded. Pay once for Roll Pro, no subscription."
- When Find ships [this session], 166: "Type "beach last summer" and Roll finds the trip. Type "screenshots" and clear
  them. Roll's AI runs on your iPhone, so nothing is uploaded. Pay once, no subscription."

**First three screenshot captions** (real demo library; numbers "about" and identical to what the screen shows)

1. **Find the trip in one sentence** / *"Puerto Rico 2024": the whole trip, ready to be an album.* Screen: answer
   grouped by day with Make album. [this session]
2. **Get your space back** / *Roll found about {X} GB you don't need.* Screen: taste scan result. [today]
3. **Nothing leaves your iPhone** / *On-device AI. No upload, no account. Pay once.* Screen: Ask Roll status line or
   the intro page. [today]

**Keyword field (100 chars), with the recommended subtitle:**
`search,album,trip,finder,duplicate,screenshot,storage,cleanup,blurry,compress,organize,remover,video`
Dropped vs live: `space` (now in the subtitle), `gallery`, `delete`, `swipe` (lowest value). Added: `search`, `album`,
`trip`, `finder`, `video`. Never repeat name or subtitle words (roll, private, ai, photo, cleaner, clear, find, your).
If the subtitle is "Free up space. Find any photo.", the same field works.

**What to A/B** (no test runs without the founder)

- Product Page Optimization (screenshots only; Apple doesn't test subtitles): A = Find-first (captions above),
  B = Clear-first (outcome draft order). 50/50, run to Apple's confidence, read conversion rate.
- Subtitle: sequential, one version each, compare impressions → page views → downloads in App Analytics over equal
  weeks.
- Custom Product Pages for later Apple Ads: a Find page (trip screenshots first) for search-intent ad groups and a Clear
  page for cleaner terms. Drafting only; no campaigns.

## 5. Launch posts with the Find story

Both drafts in `docs/design/launch/` stay as the first posts. Two changes and one follow-up each.

**Fix in the Reddit title:** "Searching 29,682 photos offline in ~15 ms" mixes up numbers. ~15 ms is the warm *preset
pile* (14.5 ms); typed search is 24–29 ms warm with the query embedding. Use "in ~25 ms", or say "preset piles in
~15 ms". Also, "Neural Engine" is in both posts: keep it only if a phone measurement shows the model on the ANE
(ADR-0005); otherwise "on-device".

**Reddit r/LocalLLaMA follow-up (after the eval):** "I measured how well on-device EmbeddingGemma 2 finds trips in my
own 29,682-photo library." Body: the find eval in prose (queries the way people search, labels from my albums plus a
vision model judging thumbnails), P@10 and nDCG@20 per query group **[eval]**, what moved them (query template, date
and place words from an offline GeoNames list with no network geocoding, grouping photos into events), and where it
still fails. Add one line for the find examples: *"Puerto Rico 2024" returns the trip, "soccer" returns the games,
"receipt March" returns the receipt.* Only the ones the eval passes.

**LinkedIn follow-up:** open with the user behaviour, not the feature. Sketch (fill the bracket only with a real
story, with permission): *"I built Roll to delete screenshots. Then [a friend] used it to find every photo from her
trip, made an album, and sent me the video she cut from it. That's not what I built it for, so this week I built it for
that."* Then in prose: date and place words, answers grouped into trips, Make album, an album that offers new soccer
photos and waits for a yes; still nothing uploaded; one measured number from the eval and one from the phone. Close with
one question: "What would you make an album of?" No labelled sections.

## 6. Numbers marketing may quote

Measured (sources: `docs/investigations/2026-10-29-search-and-piles-results.md`, `2026-10-29-pile-eval.md`, launch
posts). All on the founder's iPhone 13 Pro Max, Debug build; say "on my iPhone 13 Pro Max".

- Library: 29,682 photos and videos. Screenshots pile: 2,532. Duplicates: 3,219 items. Blurry photos: 67 (about
  0.32 GB).
- Typed search: 24–29 ms warm, query embedding included. Preset piles: 7.8–14.5 ms warm.
- Photo embeds in 64 ms; query in 6.7 ms. Model: one-time 343 MB download. Indexing: 29,685 items in 75.8 min,
  0 failures (heat pauses included).
- Pricing: search is free; the first 50 applied items are free; Roll Pro is one payment, no subscription.
- Storage: only "about {X}" from a real scan shown on screen; never a typical or average figure.

Pending this session (do not quote until the note `docs/investigations/2026-11-15-find-eval.md` or A8 has it):

- P@10 / nDCG@20 for trip, activity, event and thing queries **[pending eval]**
- "Nothing found" rate on nonsense queries **[pending eval]**
- Answer size after event grouping (photos per trip answer) **[pending eval]**
- Share of the library with a location (what place search can reach) **[pending eval]**
- Time from typing a trip to an album in Photos **[pending A8]**
- Typed search time with date and place understanding on the phone **[pending A8]**
- Memory video export time **[pending A6; no claims, feature not shipped]**

## Flagged as risky

1. **Free tier vs albums.** "Make album" commits through the existing committer, so each added photo counts toward the
   first 50 free items. A 200-photo trip album hits the paywall on the first try. Ads must not say "free albums";
   founder to decide whether album adds count.
2. **"Keeps itself updated"** (living albums) reads as automatic. Say "offers new photos, you say yes" (guardrail: Roll
   changes nothing on its own).
3. **"Find any photo" / "in seconds"**: recall and timing are unmeasured. Hold until the eval and A8.
4. **"Neural Engine"** in the launch posts and guardrails: needs an on-phone measurement (ADR-0005), else "on-device AI".
5. **Reddit title "~15 ms"** applies to preset piles, not typed search (24–29 ms).
6. **Birthday/kids ads (#10)**: highest emotional pull and highest risk of a visibly wrong answer. Last to run.
7. **Location** is new data in Roll's database. The privacy policy and App Privacy answers need a check that offline
   place lookup (no network) is described before Find ships.
