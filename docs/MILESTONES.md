# Milestones

Each milestone maps to a group of tasks in `docs/superpowers/plans/2026-10-22-roll.md`.

- [x] **M1 Foundations (Tasks 1-3).** Scaffold, `Embedder` protocol and stub, Store (GRDB schema, repositories, VectorStore, FreeQuota).
  Done when: `just gen && just build` succeeds with an empty RootView and `swift test` passes for Embedding, Store and Entitlements.
- [ ] **M2 Signals and library (Tasks 4-5).** Vision signals, PhotoKit access, size estimates.
  Done when: signal tests pass on fixtures and SizeEstimator tests cover every branch with exact integers.
- [x] **M3 Indexer (Task 6).** Pipeline, thermal gate, background scheduling.
  Done when: 450 fake assets index in 3 batch commits, thermal delays do not fail, and cancellation keeps committed rows.
- [x] **M4 Ranking (Task 7).** Presets, scorer, classifier, swipefile engine.
  Done when: the classifier separates seeded clusters above 0.95 accuracy and the engine never repeats a decided asset.
- [x] **M5 Dedupe (Task 8).** Duplicate grouping and keeper policy.
  Done when: window and phash grouping and keeper ordering tests pass.
- [ ] **M6 Squish (Task 9).** Video and photo re-encode, replace flow, journal.
  Done when: unit tests pass (fake library with real per-asset state), and the basic flow plus the device QA checklist below are ticked on a device (PhotoKit writes are not unit-testable).
  - [ ] Basic flow: squish a 1080p video and a JPEG over 3 MB; the copy keeps date, location, favorite, hidden state and albums; EXIF/GPS survive; the originals go to Recently Deleted after one confirmation covering the whole batch.
  - [ ] iCloud-only original downloads on Wi-Fi with progress. Don't Allow on the delete prompt: copies and originals all stay (`userDeclinedDelete`); retry and "discard copies" both work. After a delete the UI says space is freed after Recently Deleted is emptied (or in 30 days), not immediately.
  - [ ] **Squish device QA (blocks real-user builds).** Decision: Dolby Vision, HEIC, DNG/ProRAW, ProRes and Apple Log sources are refused in v1.
    1. Limited library: set access to "Selected Photos" in Settings. Squish refuses with a full-access prompt, creates nothing and deletes nothing. After granting full access, squish an item that sits in two albums and check it is still in both.
    2. Edit after prepare: prepare a batch, edit one original in Photos (crop, filter) before confirming. That original is not deleted and is reported as skipped; the others are deleted.
    3. Favorite or album change after prepare: favorite another original, and add a third to an album, before confirming. Both are skipped; nothing is lost.
    4. Manually sorted album: put an item in an album with a manual order. The copy sits right after the original, and takes its position once the original is deleted.
    5. HDR photo: squish an HDR iPhone photo (gain map). It still shows HDR in Photos, with the same colours (Display P3). A CMYK JPEG is refused.
    6. HDR video: squish a 10-bit HLG video that is not Dolby Vision (for example from a third-party camera app). It stays 10-bit HDR; compare on an HDR display. An iPhone video recorded with the default HDR setting is Dolby Vision and is refused with `unsupportedFormat`.
    7. Refused formats: ProRes video, Apple Log video, HEIC photo, ProRAW/DNG and a RAW+JPEG pair each show a clear reason; nothing is created.
    8. Other refusals: edited photo or video, burst member, Live Photo, Portrait (depth), spatial photo or video, slo-mo, cinematic, and an item from a shared album or synced from a computer. Nothing is created.
    9. Portrait 4K video with two audio tracks: the copy plays upright at 1080x1920, keeps both audio tracks, location and date, and the UI showed "1080p (from 4K)" beforehand.
    10. Bad download: interrupt an iCloud download (Airplane Mode mid-transfer) and use an optimised-storage original. Squish refuses or reports `needsDownload`; no copy is created, no scratch files remain.
    11. Kill the app: swipe it away after "saving" starts but before the delete prompt. On relaunch `reconcile()` lists the verified pair (retry or discard) or the unverified orphan; no silent duplicate remains; the copy is absent from Duplicates and from Squish suggestions.
    12. Background: send the app to the home screen mid-encode. The item finishes or cancels cleanly, the batch stops when time expires, no watchdog kill, no leftover scratch files. Cancel mid-download and mid-encode: no new asset.
    13. Disclosure: with iCloud Shared Library on, the confirm sheet lists "If you use iCloud Shared Library, squished items are moved to your Personal Library and removed for other participants." and "Captions, keywords and people tags you added by hand aren't kept." Check both are true afterwards.
    14. Read-back and space: the stored copy's size and SHA-256 equal the encoded file on a real device (if Photos rewrites the container this verification fails; record how often). On a nearly full device, squish refuses with an insufficient-space message before exporting anything.
- [ ] **M7 Monitor, Commit, Entitlements (Tasks 10-12).** Samplers, commit planner and committer, RevenueCat wrapper.
  Done when: parser, planner and quota tests pass, and the paywall reads real offerings in a sandbox account.
- [ ] **M8 App shell and features (Task 13).** Onboarding, Home, Swipefiles, Duplicates, Squish, Monitor, Paywall.
  Done when: every feature screen is reachable and the app runs end to end on StubEmbedder.
- [ ] **M9 Verification and release (Tasks 14-16).** Seeded simulator smoke test, real-embedder test, CI, App Store Connect, RevenueCat, internal TestFlight.
  Done when: `just uitest` passes, CI is green, and an internal TestFlight build is processed. Stop before review submission.
