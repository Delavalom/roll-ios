# Apple Ads for Roll 1.1: proposal (nothing created, nothing spent)

Prepared 2026-11-16 with read-only `asc ads` calls (Platform API v1, ad account 24268190, profile AppSprint).
**Creating any of this needs the founder's explicit OK**, and should wait until 1.1 is live (the ads sell Find).

## What exists today

- Campaigns in the ad account: **none** (`asc ads campaigns find` → `[]`; legacy v5 list → `[]`).
- Roll (adamId 6826174715) is eligible and owned (`asc ads apps search --return-owned-apps`).
- Caps to respect: the factory-aso daemon's $2 CPT and $20/day. `asc` doesn't enforce them, so the files below do.

## Demand signals

Apple Ads keyword suggestions for Roll (`asc ads suggestions keywords find`, popularity 0–100, US), which follow the
current listing, so they are all cleanup terms:

| Keyword | Popularity |
|---|---|
| clean up iphone | 65 |
| photo roulette | 62 (a game; negative) |
| swipewipe | 57 (competitor brand; negative, no competitor terms) |
| ai photo editor | 56 (wrong intent; negative) |
| photo delete swipe | 54 |
| photo cleaner | 50 |
| delete photos | 49 |
| recover deleted photos | 46 (wrong intent; negative) |
| clean up photos free | 45 |
| roll private ai photo cleaner | 5 |

Competition from `asc optimize keywords score` (difficulty 0–100, public top results; Apple's popularity source
returned no rows this week): find my photos 11.6, trip photos 15.6, find photos 16.3, trip album 19.1, photo finder
20.6, ai photo search 24.7, clean up photos 28.9, photo organizer 31.4, photo search 32.3, storage cleaner 43.3,
duplicate photo cleaner 46.0, photo cleaner 71.0. Find terms are cheap and thin; cleanup terms have the demand.
factory-aso (popularity estimates, rank tracking) was **down** (connection refused) during this work.

## Proposed structure (all PAUSED, US, manual CPT, exact match)

| Campaign | Daily budget | Default bid | Keywords | Why |
|---|---|---|---|---|
| Roll US Search Clear 1.1 | $10 | $1.50 | `clear-keywords.json` (9) | Where the demand is; sells "Get your space back" |
| Roll US Search Find 1.1 | $8 | $1.00 | `find-keywords.json` (10) | Cheap, low-competition find terms; tests whether Find converts |
| Roll US Search Brand 1.1 | $2 | $0.50 | `brand-keywords.json` (4) | Protect the name |
| **Total** | **$20/day** | max $1.50 | | Under the $20/day and $2 CPT caps |

Negatives for all three (`negatives.json`): recovery, editors/enhancers, games, reverse image search, Find My, photo
books/prints, and the competitor brand.

Search Match off (automatedKeywordsOptIn false) until there's a week of data. A Find custom product page (trip
screenshots first) would raise the Find campaign's relevance: draft it once the 1.1 screenshots are approved.

## How to create (only after the founder's OK)

The campaign files follow the CampaignCreate shape `asc` documents, with `"status":"PAUSED"`, so creating them starts
no delivery. The ad-group and keyword files are drafts: `asc` names their schemas (AdGroupCreate,
KeywordCreateBulkRequest, NegativeKeywordCreateBulkRequest) but doesn't print the fields, so check them against
Apple's v1 reference first and replace `CAMPAIGN_ID` / `AD_GROUP_ID` with the IDs each create returns.

```bash
asc ads campaigns create --ad-account 24268190 --file clear-campaign.json      # PAUSED, no --confirm needed
asc ads ad-groups create --ad-account 24268190 --file clear-ad-group.json --confirm
asc ads targeting-keywords create-bulk --ad-account 24268190 --file clear-keywords.json --confirm
# then Find and Brand the same way; resuming a campaign (spend) is a separate, explicit step:
asc ads campaigns resume --ad-account 24268190 --campaign CAMPAIGN_ID --confirm
```
