# Find launch posts (DRAFT, 2026-11-16, for Roll 1.1)

Follow-ups to the first launch posts in `docs/design/launch/`. **Nothing here is posted.** The founder posts, after
1.1 is live on the App Store. Every number comes from `docs/investigations/2026-11-15-find-eval.md` (round 4) and is
said with its conditions: the founder's iPhone 13 Pro Max, a Debug build, one library, one judge. No "Neural Engine"
(ADR-0005: no on-phone measurement of it yet), no memory videos (off in Release), no Roll-made video.

Video for both: the 1.1 demo (`docs/marketing/find-demo-video.md`), recorded on the iOS Simulator with a CC0 demo
library. Say so in the post ("demo library, recorded on the simulator").

## Reddit, r/LocalLLaMA

**Title:** I measured how well on-device EmbeddingGemma 2 finds trips in my own 30k-photo library

**Body:**

A few weeks ago I posted Roll, an iPhone app that runs EmbeddingGemma 2 on the phone to search and clean up the
camera roll. The most common thing people did with it wasn't cleanup. They searched for a trip and wanted the photos
in one place. So I built that ("Find") and measured it before saying anything about it.

The eval: 49 queries on my own library (30,422 photos and videos), written the way people search: activities
("soccer"), events ("birthday cake with candles"), places and trips, things ("my dog"), queries made from my own
albums, two dated ones ("christmas 2023", "beach last summer"), and 12 nonsense strings. Every result tile in the
pooled top results was judged.

What I found:

* The plain vector search was already decent at the top (P@20 .82) but answered far too much: a median of 676 photos
  per query, about a quarter of them relevant. You can't make an album from that.
* Cutting the answer at 0.6 of the best score kept P@20 the same and shrank answers to a median of 69 photos.
* Dates had to become filters. "christmas 2023" went from P@20 0 (the right photos were in there, buried among 836)
  to .95: 23 photos, 22 of them from that Christmas.
* Places are soft, not hard. Only 18.6 % of my library has a location (WhatsApp saves never do), so filtering on place
  dropped queries made from my trip albums from .80 to .48. Now a located photo in the place gets a bonus, a located photo elsewhere is
  dropped, and an unlocated one still competes on meaning. Trips scored P@20 .93.
* Place names come from a GeoNames list bundled in the app. No geocoding service, no network.
* A "nothing found" floor (best cosine under 0.735) refused 9 of the 12 nonsense strings and none of the 37 real
  queries. The margin is thin: nonsense runs 0.694 to 0.741.
* Speed on the phone, Debug build, warm: 35 to 46 ms per query, all steps included. About half the drop from ~200 ms
  was fixes, half was Low Power Mode being off for the second run.

Where it still fails: "beach last summer" has only 2 relevant photos, so its ceiling is low; "things" are the weakest
group (.71); and every threshold here was tuned on one library and one judge. I'd like more libraries before trusting
them.

Model and Swift package are Apache 2.0 (Delavalom/embeddinggemma-coreml); the app is source-available under PolyForm
Noncommercial (Delavalom/roll-ios); the eval method is in the repo (ADR-0006 and the find eval note).

Video: the demo library, recorded on the simulator. Happy to answer questions about the eval.

## LinkedIn

Open with what people did, not the feature. **Fill the bracket only with a real story, with permission; otherwise
use the second opening.**

> I built Roll to delete screenshots. Then [a friend] used it to find every photo from her trip and make an album. That's
> not what I built it for, so this week I built it for that.

Second opening (no story needed):

> I built Roll to clear space on my iPhone. The thing people kept doing with it was searching for a trip.

Body (prose, no labelled sections):

Roll 1.1 adds Find. You type a trip the way you'd say it, a city and a year, a holiday, a season, and Roll answers
with the trip grouped by day. Make album turns it into an album in Photos, with only what you picked. An album can
stay up to date: when new photos look like they belong, Roll shows them on Home and waits for a yes. It never adds
anything on its own.

Still nothing leaves the phone. Place names come from a list built into the app, so where your photos were taken is
never looked up online. Making albums is free; the free tier only counts deletes and squishes.

I measured it before announcing it, on my own library of about 30,000 photos: "christmas 2023" went from 0 to 19 of
the top 20 right, answers shrank from a median of 676 photos to 69, and a search takes 35 to 46 ms on my iPhone 13
Pro Max. One library, one judge, so I'm treating those as a start.

What would you make an album of?

(Links in the first comment: App Store, roll.delavalom.com. Attach the demo video.)

## X / Threads (short)

1. Type the trip. Get the trip. Roll 1.1 finds "Lisbon 2024" in your camera roll, grouped by day, and makes the album.
   All on your iPhone. [video]
2. Most photo search answers with hundreds of photos. Roll's Find answers with a median of 69 on my 30k-photo library,
   and says "nothing clearly matched" when nothing does.
3. Place names in Roll come from a list built into the app. Your photos' locations are never looked up online.
4. Albums are free in Roll. Only deletes and squishes count toward the free 50. Roll Pro is one payment.
5. "christmas 2023" on my library: 19 of the top 20 are from that Christmas. Before the date filter: 0.

## TikTok / Reels / Shorts caption (with the demo video)

> Every photo from the trip, one sentence. Roll finds it on your iPhone, groups it by day, and makes the album. Then it
> clears the screenshots. Nothing uploaded. (Demo library, recorded on the iOS Simulator.)
> #iphonetips #photography #travel #privacy
