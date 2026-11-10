# Praktika learnings for Roll (2026-11)

Source: Sub Club (RevenueCat) interview with Adam Turaev, CEO of Praktika, an AI tutor app at $50M ARR, released
2026-10-28: https://www.youtube.com/watch?v=g6RoPxoCqLA. These are one founder's self-reported numbers, so treat them
as a single data point. The L numbers match the portfolio-wide list.

Roll's business model since 2026-11-10: Roll Pro is a one-time purchase. Pay once, no subscription, nothing renews.
Everything below is written for that model.

## What applies to Roll

**L1. Sell the outcome, not the feature.** Praktika never sold "learn English" in Brazil. It sold "get a better job",
anchored as "50x cheaper than a tutor". Roll's outcome is getting space back without handing your photos to anyone.
On-device AI, swipefiles and squish are how it gets there, so they're the proof, not the headline.

*Where it landed:* PR #3 already made the paywall lead with the outcome in the strongest form: the user's own number
("Free about 3.2 GB on this iPhone", the same figure the taste scan or Home showed) with the top categories under it.
This PR only covers the case without a number (below 100 MB, an iCloud-only library, or the paywall opened before
Home has loaded). There the header is now "Get your space back without uploading your photos", with the line "Roll's
AI works on your iPhone and you decide what goes. Make room before you pay for more storage." (`PaywallPitch.generic*`
in RollCore, tested against the copy rules). The feature rows stay as they are, because the headline already says the
outcome.

*The anchor is one-time.* Praktika's anchor was a cheaper alternative. Roll's is the shape of the payment: pay once
and keep it, against paying again every month for more storage. In the app the "Pay once. No subscription." words
belong on the price card and in the terms under the button (the one-time paywall change). The header doesn't repeat
them. We don't quote iCloud+ or any other storage prices, because they vary by country and change. We don't put a
number on "cheaper" either. The App Store draft is in `docs/aso/2026-11-outcome-first-draft.md`.

**L5. Playful in marketing, strict in the product.** Praktika's worst experiment of the year was putting its viral
"unhinged" avatars inside the app. The fix was a one-page doc of what the product does and doesn't do.
*Done in this PR:* `PRODUCT_GUARDRAILS.md`, built from the code, ADRs and privacy policy, including "Charge once".
Reels can be as loud as they like, but a growth idea that bends a guardrail (an upload, an automatic delete, a
performance claim, a recurring charge) needs the founder's call first.

**L7. Quality first, and inference ends up on the device.** Praktika's CEO expects models to run on-device in the
end. Roll starts there: EmbeddingGemma on the Neural Engine, with no server and no inference bill. That is also what
makes a one-time price workable: a user who keeps cleaning for years costs Roll nothing per use. The quality bar from
L7 still applies. Keep "search unavailable" honest when the model can't load (never the stub), and keep improving
pile quality with the pile eval (`scripts/eval/`) rather than cutting corners for speed.

**L8. Native won.** Praktika's biggest win of the year was moving from Flutter to native iOS, which improved every
conversion and engagement metric they track. Roll is native SwiftUI already. That's the validation, and the lesson
for the factory is to default new apps to native iOS.

**L10. Know why people came.** Praktika asks "why are you here" during onboarding. The top answer, fear, shaped the
product. *Not built, on purpose.* The first version of this PR added an optional "What brought you here?" page with
four answers that picked the paywall headline. After PR #3 it was dropped, for three reasons:

1. PR #3 cut onboarding to one intro page so the taste scan's number (the aha) comes sooner. A question page in front
   of the permission ask doubles what stands before it. Putting it after the scan delays the paywall instead.
2. The paywall is already personal, and with better data: the headline is the user's measured number, and the line
   under it names what was actually found. A self-reported reason would compete with that line, not add to it.
3. The answer would never leave the iPhone (no analytics, RevenueCat gets no attributes), so it can't teach us why
   people came, which is the point of L10.

If L10 comes back, it should be measured with consent, and asked after the first cleanup rather than before the aha.

## Open for the founder

- **Approve the copy.** The header without a number and its line (above), plus the ASO draft.
- **Measuring why people came.** Counting answers would need either a privacy-policy change or an opt-in survey.
  Today's choice keeps the "no analytics" promise. Decide before building any question.
- **Paywall screenshot for App Review.** Capture the in-app purchase review screenshot after the one-time paywall
  and this header are both on main, so it shows what ships.
- **Next personalization (not built).** After onboarding, open the biggest found category first (Screenshots,
  Duplicates or the Squish card). It uses the taste scan's own numbers, so it needs no question.
- **L2–L4 (creators, viral format)** belong to the growth lanes, not this repo.
