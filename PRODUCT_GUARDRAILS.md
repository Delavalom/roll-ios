# Roll product guardrails

One page on what Roll does and doesn't do. Marketing can be as playful as it likes; the product follows this page.
Every line here comes from the code or an accepted doc (sources in brackets). If the code changes, update this page
in the same PR. If a growth idea needs one of these lines to change, the founder decides first.

Roll is a photo cleanup tool. It helps you find what you don't need and you decide what goes. It's not a companion,
a feed or a backup service.

## Roll does

- **Analyze photos on the iPhone only.** EmbeddingGemma runs on the Neural Engine, plus Apple's on-device Vision and
  Sensitive Content Analysis. [AGENTS.md Rules, docs/legal/privacy-policy.md]
- **Ask before anything changes.** Swipes only queue a decision, and Undo takes the last one back. Nothing
  happens to the library until Review & apply. iOS then shows its own delete confirmation, and if you tap Don't
  Allow, nothing is deleted. [SwipeReviewView, CommitSheet, ReplaceFlow]
- **Keep deletes recoverable.** Deleted items go to Recently Deleted for 30 days, and the app says so. Space is
  freed only once that is emptied. [CommitSheet, ReplaceFlow.swift]
- **Keep one shot of each duplicate group.** The commit planner drops a delete that would remove every shot in a
  group. [Commit/CommitPlanner.swift `protecting:`]
- **Squish safely.** A smaller copy is verified before its original is touched. The copy keeps the date, location,
  favorite, hidden state and albums. The original goes to Recently Deleted. An interrupted squish is journaled and
  finished or undone from Home. The confirm sheet lists what can't be carried over. [spec §8, Squish/ReplaceFlow.swift]
- **Lock the Private pile** behind Face ID or the passcode, and hide app thumbnails in the app
  switcher. [spec §13, SwipefileListModel, PrivacyOverlay]
- **Give the first 50 applied items for free**, counted only after a change succeeds. A declined system prompt
  costs nothing. [ADR-0003, FreeQuota]
- **Say sizes as "about X"**, for photos and videos only, and only what's on this iPhone (iCloud-only originals
  are counted separately). The paywall repeats the taste scan's or Home's own number, never a new one.
  [ADR-0002, TasteScanModel, Overview/PaywallPitch.swift]
- **Charge once.** Roll Pro is a one-time purchase: pay once, keep it, restore it with the same Apple Account. No
  subscription, nothing renews. [founder decision 2026-11-10; the one-time paywall change]

## Roll doesn't

- **Upload photos, videos, thumbnails, embeddings or the words you type.** It has no server of its own.
- **Make network calls except two:** the model download from Hugging Face and RevenueCat for the Roll Pro purchase.
  [AGENTS.md Rules] (iCloud originals come from Apple's Photos framework on request.)
- **Run analytics, ads or tracking SDKs, or have accounts.** RevenueCat gets no custom user ID and no attributes.
  [privacy policy, Entitlements.swift]
- **Delete, move or squish anything on its own.** There is no background or automatic cleanup.
- **Claim performance.** Never "boost", "free RAM", "speed up" or "optimize your phone". Monitor is read-only.
  [ADR-0002]
- **Fall back to fake AI.** If the model can't load, search says it's unavailable. The stub embedder never ships.
  [AGENTS.md Rules]
- **Hide candidates to push a decision.** "Looks done" is a hint only. Weak matches are labeled "weaker match".
  [spec §5]
- **Gate the free tier behind the paywall.** It can be closed, and the free tier keeps working. [PaywallView]

## Tone inside the app

Plain, calm and specific. No jokes at the expense of someone's photos, and no shaming: Roll never calls a library
messy, even when its owner does. No countdowns, fake urgency or fake discounts on the paywall. The purchase terms
always sit under the button, readable: one payment, nothing renews, Restore works. Never quote other companies'
prices (iCloud+ or anyone else's): they vary by country and change.
