# ADR-0004: Store name "Roll: Private AI Photo Cleaner"

**Status:** accepted, 2026-10-23

## Context

The App Store name must be unique and at most 30 characters. It also carries most of the keyword weight. Short brand names in this category are taken: Sift, Cull, Pile, Kept, Sorta, SwipeFile, TidyRoll (four apps), CleanRoll, ClearRoll and SlideRoll. The US results for "ai photo cleaner" are crowded with "X: AI Photo Cleaner" titles, and the leaders have 100k–750k ratings. Almost none of them lead with privacy.

What sets Roll apart is that everything runs on the phone: EmbeddingGemma 2 on the Neural Engine, nothing uploaded, no analytics besides RevenueCat.

## Decision

- **Name:** `Roll: Private AI Photo Cleaner` (30 characters). It keeps the codename as the brand, and it covers the "ai photo cleaner" and "photo cleaner" terms plus a "private" differentiator no competitor holds.
- **Subtitle (draft):** `Describe it. Swipe it. Gone.`
- **Fallback** if App Store Connect rejects the name as taken at record creation: `Roll – Private Photo Cleaner`, then `Roll: On-Device Photo Cleaner`.
- **Bundle id:** `com.delavalom.roll` (registered 2026-10-23, portal id D2YCT998JL). **SKU:** `ROLL001`.

## Consequences

The name can change until the first App Store submission, so a later rename costs nothing. Keyword field and screenshots are drafted with the ASO tooling before external release. The internal TestFlight build doesn't depend on them.
