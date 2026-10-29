# Device QA, 2026-10-23: problems and runbook

Part of [Device QA, 2026-10-23](../device-2026-10-23.md).

## Top problems, ranked

1. **iCloud-only libraries are almost entirely unanalysed, and the UI shows blank cards.** 98.4% of thumbnails were "in iCloud" with network access off; only 1.6% of assets got signals, `cloudOnly` rows are never retried (`run()` is never called with `allowNetwork`), and the 900 px swipe card is blank for those assets. Optimize iPhone Storage is common on full phones, which are exactly Roll's users. Measure with `-QAThumbProbe` which sizes or delivery modes are local (Photos keeps small derivatives), then index from the largest local derivative and/or retry `cloudOnly` on Wi-Fi with network allowed, and give cards a local low-res fallback.
2. **"You can free about X" isn't device space.** 39.57 GB promised on a phone with 9.3 GB free; estimates are of originals that live in iCloud. Split "on this iPhone" from "in iCloud", or weight by local availability.
3. **Squish numbers can't be delivered.** 12,031 candidates preselected ("saves about 77.71 GB") while Home says 28.2 GB; Dolby Vision (the iPhone HDR default) is only refused at export time, and every visible candidate needs a download that's switched off. Pre-filter Dolby Vision where possible, don't preselect cloud items when downloads are off, cap or batch the default selection, and use the same savings figure on Home and Squish.
4. **Thermal pauses dominate.** `serious` within 48 s of launch, during the sync alone (enumerating 29.6k assets and looking up UTIs), while charging; 266 of 600 s paused. Defer the UTI lookups or batch them across launches, and repeat unplugged.
5. **Screenshot size estimate is likely 1.5–4× high** (PNG 1.6 B/px). Calibrate against real files (Squish measures real bytes).
6. **Layout:** Squish row subtitle wraps into columns; the size line wraps; "about 0 MB" rows; the Monitor's 183 GB estimate under a 115 GB gauge.

## Still to run

Run in this order once the phone is unlocked with Auto-Lock set to Never:

```bash
D=YOUR_DEVICE_UDID
# Read-only probe: local thumbnail sizes and Vision time per image (about 4 minutes; then terminate)
xcrun devicectl device process launch --device $D --terminate-existing com.delavalom.roll -- -QAMetrics -QAThumbProbe
# Paywall, Dynamic Type, then the Test Store purchase and restore
TEST_RUNNER_ROLL_DEVICE_QA=1 xcodebuild test-without-building -scheme Roll -destination "id=$D" -derivedDataPath build/dd \
  -only-testing:RollUITests/DeviceQAReadOnlyTests/testP2PaywallAndLargeText \
  -only-testing:RollUITests/DeviceQAReadOnlyTests/testP3TestStorePurchaseUnlocksPro -resultBundlePath artifacts/qa/p2.xcresult
# Part 2, once "Roll QA" exists with at most 40 throwaway items. Stage the restock files first (see "Restocking the
# QA album"); testD00RestockAlbum imports them before D0
scripts/qa_restock.sh $D
TEST_RUNNER_ROLL_DEVICE_QA=1 TEST_RUNNER_ROLL_DEVICE_QA_DESTRUCTIVE=1 xcodebuild test-without-building -scheme Roll \
  -destination "id=$D" -derivedDataPath build/dd -only-testing:RollUITests/DeviceQADestructiveTests \
  -resultBundlePath artifacts/qa/d.xcresult
scripts/qa_pull.sh $D artifacts/qa/p2.xcresult artifacts/qa/d.xcresult
python3 scripts/qa_summary.py artifacts/qa/device/metrics.jsonl
```

Automated Part 2 cases (`DeviceQADestructiveTests`), all with `-QAAlbum "Roll QA"`:

- **D00:** restock (`-QARestock`): imports the staged local originals into the album, filling it to 32 items at most so the copies D3–D5 save never take a relaunch over 40. With nothing staged it still brings an album over 32 back down (only iCloud-only items leave, and only the album). Skipped when nothing is staged and the album is within 32.
- **D1:** album inventory (type, format, size, duration, Squish's up-front eligibility), Squish candidates and refusals, the Dolby Vision export experiment (temp files only). Changes nothing.
- **D2:** case 14 space: `-QAFakeAvailableBytes 100000000` must refuse before exporting, with no prompt.
- **D3:** case 11: pause before the delete prompt, kill, relaunch; reconcile lists the pair; screenshots of Squish and Duplicates; "Remove copies".
- **D4:** case 12: home button mid-encode, 45 s, back.
- **D5:** basic flow + case 13 disclosures + "Don't Allow" (copies and originals stay) + "Replace the originals"; per-item bytes, read-back (SHA-256) refusals, and metadata survival (date, location, favorite, hidden, albums) land in `squish_prepared`, `squish_failed` and `squish_copy_after_delete`.

## Manual steps for the user (on the phone)

Never run destructive steps from the home-screen icon: without `-QAAlbum` the scope gate is off. Launch QA mode from the Mac with:

```bash
xcrun devicectl device process launch --device YOUR_DEVICE_UDID --terminate-existing com.delavalom.roll -- -QAAlbum "Roll QA" -UITestSkipPaywall
```

(add `-QAPauseBeforeSquishDelete` where noted). A yellow "QA · Roll QA · N items" badge at the top confirms QA mode.

- **M0 (now): settings and storage.**
  1. Unlock the phone.
  2. Set Settings > Display & Brightness > Auto-Lock to Never.
  3. Note Settings > General > iPhone Storage: "X GB of 128 GB used", for comparison with the Monitor's 9.31 GB available.
  4. Leave the phone on the cable, but tell the agent whether it's charging.
- **M1: build the "Roll QA" album (40 items or fewer, all throwaway).** Create it in Photos > Albums > + > New Album. Include:
  - a 1080p H.264 video (for example a downloaded or messaging-app clip);
  - a JPEG over 3 MB (Camera > Formats > Most Compatible, then take a photo, which also gives an HDR JPEG with gain map for case 5);
  - an iPhone video with HDR on (Dolby Vision);
  - an HEIC photo (Formats > High Efficiency);
  - a 10-bit HLG video that isn't Dolby Vision, from a third-party camera app (case 6);
  - a ProRAW photo and a short ProRes clip (Camera > Formats; case 7);
  - a Live Photo, a Portrait photo, a burst shot, a slo-mo and a Cinematic clip (case 8);
  - one edited photo (crop it in Photos; case 8);
  - one photo that is also in a second album, and one album set to manual order (Photos > album > ⋯ > Sort > Custom Order, then drag the photo; case 4);
  - one old item that's only in iCloud (case 10).
  - Then tell the agent: it runs D1–D5.
- **M2: case 1, limited library.**
  1. Settings > Privacy & Security > Photos > Roll > Limited Access, and select two "Roll QA" items.
  2. Launch QA mode, open Home > Big videos (Squish): it must say "Squish needs Full Access to Photos" and the Squish button must be disabled. Nothing is created (check the Recents count in Photos).
  3. Set access back to Full Access, launch QA mode, and squish the item that sits in two albums. In Photos, check the copy is in both albums.
- **M3: cases 2 and 3, change after prepare.**
  1. Launch QA mode with `-QAPauseBeforeSquishDelete`.
  2. In Squish, select three photo or video candidates and tap Squish, then Squish N items.
  3. When "QA paused before deleting…" appears, switch to Photos:
     - crop original 1;
     - favorite original 2;
     - add original 3 to another album.
  4. Return to Roll and tap "QA: continue to delete", then Delete on the prompt.
  5. Expected: the sheet says three originals were kept because they changed, and nothing is lost (copies and originals are both in the album). Then "Remove the copies".
- **M4: case 4, manually sorted album.** After D5 (or any squish of the item in the custom-order album), open that album in Photos: the copy must sit where the original was.
- **M5: cases 5 and 6, HDR looks.** After D5, compare the squished HDR JPEG and the HLG video with the originals in Recently Deleted on the phone (an HDR display). HDR highlights and colours must match. A CMYK JPEG must be refused (only if you have one).
- **M6: case 9, portrait 4K with two audio tracks.** Only if you have such a file (for example from a third-party recorder). Squish shows "1080p (from 4K)"; the copy plays upright at 1080×1920 with both audio tracks.
- **M7: case 10, bad download.**
  1. In QA mode turn on "Allow iCloud downloads (Wi-Fi)", select the iCloud-only item and tap Squish.
  2. Turn on Airplane Mode while it shows "downloading from iCloud".
  3. Expected: "Only in iCloud…" or a download failure, no new item in Photos.
- **M8: case 12, cancel.** Start a squish of a large video, then swipe the sheet down or kill the app mid-download and mid-encode. No new asset may appear in Photos.
- **M9: case 13, iCloud Shared Library.**
  1. Only if Shared Library is on: put a shared-library item in "Roll QA" and squish it.
  2. Check the confirm sheet lists both disclosure lines.
  3. Afterwards, check the copy is in your Personal Library and that a caption you'd added isn't kept.
- **M10: Face ID re-lock (Private swipefile).** Open Swipefiles > Private and authenticate. Send Roll to the background for 10 s and come back: it must ask for Face ID again, and the app switcher must show the privacy cover, not photos.
- **M11: case 14, Photos rewriting the copy.** Nothing manual: D5 records any "copy content differs from the encoded file" refusals in `squish_failed`.

## Harness (for the next run)

- `-QAAlbum <title>` (DEBUG): the library source lists only that album, so the Store, Squish, Duplicates, swipefiles and the commit planner see nothing else. `QAAlbumGate` re-reads the album before every delete, album move, squish, squished-original delete and copy removal, and refuses (with a clear "QA scope: …" error) any id outside it, or a missing, ambiguous or over-80-item album. The UI tests refuse to start above 40 items. Any `-QAAlbum` run (even with a missing title) keeps its own database, vector index and onboarding flag (`Application Support/qa/Roll/`, defaults suite `com.delavalom.roll.qa`): an album-scoped sync would otherwise mark the rest of the real library deleted, and `-UITestResetState` then resets only the QA copy. An unfinished squish from an album run is therefore seen by the next album run (D0), not by a normal launch.
- `-UITestResetState` never loses an unfinished squish: with open journal rows it keeps `squishJournal` and empties everything else (`AppDatabase.resetForUITests`, event `ui_test_reset`).
- `-QAMetrics` without an album is read-only: every change is refused (`QAReadOnlyGate`).
- `-QARestock` (with `-QAAlbum` only): imports the files in Roll's `Documents/qa-restock/` into the album (see "Restocking the QA album").
- Other flags: `-QAPauseBeforeSquishDelete`, `-QAFakeAvailableBytes <n>`, `-QADolbyVisionExperiment`, `-QAThumbProbe`, `-QAExhaustFreeQuota`, `-RCTestStore`.
- Release builds contain none of it: `just release-check` (scripts/check_release_no_qa.sh) builds Release and fails on any QA type, `-QA*` / `-UITest*` launch argument, metrics event name, "QA scope", "metrics.jsonl" or the idle-timer call in the binary, or a non-empty `RCTestStoreKey`. Run it before every TestFlight upload.
- Unit tests: `QAScopeTests` (gate rules, gated committer, chunk-by-chunk re-check, read-only gate) and `QAScopedRunnerTests` (refusal before anything is created, re-check after the pause hook, copy removal).

