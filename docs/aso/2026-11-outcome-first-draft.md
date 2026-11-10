# App Store copy, outcome first (DRAFT)

**Draft only. Nothing here is in App Store Connect.** The founder approves it, and the upload is a separate step.

What's live (read-only `asc` check of app 6826174715, version 1.0, `WAITING_FOR_REVIEW`, on 2026-11-10):

- Name: `Roll: Private AI Photo Cleaner`
- Subtitle: `Duplicates, blurs & big videos` (features, not the outcome)
- Promotional text: "Your photos never leave your iPhone. Describe what you want gone, swipe to decide, and Roll clears
  it. No subscription: pay once for Roll Pro." (privacy first, then features, then the one-time anchor)
- Description: opens "Clean up your photo library without sending a single photo anywhere. …" and has a "ROLL PRO: PAY
  ONCE" section (first 50 cleanups free, one-time purchase, nothing renews, Restore). en-US is the only locale.

Version 1.0 is in review, so any change here waits for the next version (the promotional text is the exception: it can
change without a new version). The app ships in English only (no String Catalog or `.lproj`), so there is no ES-MX
draft. Add one when the app is localized. The options below replace the subtitle and promotional text only. The
description already opens close to the outcome and already says "pay once", so leave it alone.

Rules: lead with the outcome and use the features as proof (Praktika L1, `docs/learnings/2026-11-praktika.md`). The
price anchor is one-time: "pay once, no subscription". No performance claims (ADR-0002). Sizes always "about". No
prices: not Roll Pro's (the store shows it, per country) and not iCloud+ or any other storage plan's. No competitor
names. Stay within `PRODUCT_GUARDRAILS.md`.

## Subtitle (max 30)

| Option | Chars | Note |
| --- | --- | --- |
| **Free up space. Upload nothing.** | 30 | Recommended. Outcome plus the differentiator. "Free up space" is about storage, not RAM, so it fits ADR-0002. |
| Clear space without uploading | 29 | Plainer, and it doesn't repeat "Private" from the name. |
| Free up space. Pay once. | 24 | Outcome plus the anchor. Weaker: the name already carries "Private", but "Upload nothing" is the sharper promise. |
| Get your storage back, privately | 32 | Over the limit. Kept as a reference. |
| Duplicates, blurs & big videos | 30 | Live now. A feature list, so it misses L1. |

Counts include spaces. Check them again in App Store Connect, which counts the same way.

## Promotional text (max 170)

> Get your space back without uploading a single photo. Roll's AI runs on your iPhone and you swipe to decide what
> goes. Pay once for Roll Pro, no subscription.

(158 characters.) Recommended: outcome first, privacy as the proof, the one-time anchor last, like the live text
ends.

Alternative (153 characters):

> Make room on your iPhone without uploading a photo. Roll finds screenshots, duplicates and big videos on your
> iPhone. Pay once, keep it. No subscription.

## First three screenshot captions

Each caption states an outcome and the screen underneath proves it. Use the existing screens. The figures must come
from the seeded demo library and stay "about".

1. **Get your space back** / *Roll found about {X} GB you don't need.* Screen: the taste scan result ("You can free
   about …") or the paywall that repeats it ("Free about {X} on this iPhone"). {X} is whatever the demo library
   really shows, and both screens must show the same {X}.
2. **Your photos never leave your iPhone** / *On-device AI. No upload, no account.* Screen: the intro page ("Nothing
   about your photos leaves your phone") or the swipe review with a card mid-swipe.
3. **Describe it. Roll finds it.** / *"screenshots of tweets", "receipts", "memes": swipe to clear.* Screen: Ask Roll
   or a swipefile with its prompt shown.

Screens 4 and up (duplicates, squish, Private pile with Face ID) can keep feature captions, because the first three
already sold the outcome. If one screen shows the paywall, it must be the one-time paywall ("Pay once. No
subscription." on the price card).

## Before uploading

- Recheck every caption against the shipping build. Squish covers big videos and large JPEG and PNG photos. Deleted
  items sit in Recently Deleted for 30 days.
- Capture the in-app purchase review screenshot of the paywall again once the one-time paywall and the new header
  without a number are both on main.
- Run the keyword field through `factory-aso` as a proposal, never as a direct write.
