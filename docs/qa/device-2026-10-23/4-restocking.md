# Device QA, 2026-10-23: restocking the QA album

Part of [Device QA, 2026-10-23](../device-2026-10-23.md).

## Restocking the QA album

Squish needs originals stored on the iPhone, and almost all of this library is in iCloud: by 2026-10-24 "Roll QA" held 40 items of which only 2 were local, both copies Roll had already made (an HEVC video and an HEIC photo), so D3–D5 had nothing real to squish. A restock adds five local Squish candidates without anyone picking photos by hand. Run it before every destructive pass (each pass squishes or removes some of them):

```bash
scripts/qa_restock.sh YOUR_DEVICE_UDID
TEST_RUNNER_ROLL_DEVICE_QA=1 TEST_RUNNER_ROLL_DEVICE_QA_DESTRUCTIVE=1 xcodebuild test-without-building -scheme Roll \
  -destination "id=YOUR_DEVICE_UDID" -derivedDataPath build/dd \
  -only-testing:RollUITests/DeviceQA2DestructiveTests/testD00RestockAlbum -resultBundlePath artifacts/qa/d00.xcresult
```

(or run the whole `DeviceQA2DestructiveTests` class: `testD00RestockAlbum` sorts first).

- `scripts/qa_restock.sh YOUR_DEVICE_UDID` runs `scripts/make_qa_restock_media.py` if a file is missing (Pillow, ffmpeg; about a minute) and copies `artifacts/qa/restock/` (gitignored) into Roll's `Documents/qa-restock/` with `xcrun devicectl device copy to`. The files: two 12 MP JPEGs (about 6.6 MB, quality 97, embedding fixtures upscaled with grain; the first has an EXIF date of 2025-05-04 10:20:30 and a GPS position in Paris), one 2400×1800 PNG photo (about 8.5 MB, not a screenshot), and two 1080p30 H.264 MOVs at 20 Mbps (8 s, about 20 MB; 45 s, about 113 MB, a "big video"), both with a QuickTime creation date and location. On the Mac, `sips` to HEIC at 0.8 saves 61–90% on the photos, well over Squish's 30% floor.
- `testD00RestockAlbum` launches with `-QAAlbum "Roll QA" -QARestock` (onboarding first if the QA database is new), waits for the yellow "QA restock: …" line (`qa.restock`), attaches it, and checks the scope badge still says 1...40 items. It is skipped with "nothing staged" when `Documents/qa-restock/` is empty.
- What the app does (`App/QA/QARestock.swift`, DEBUG only): with full Photos access, it works out how many items must leave the album so the files fit within 40, checks members oldest first with the same original-resource check as the locality scanner (network off), and takes out only as many iCloud-only ones as needed (`removeAssets`: they stay in the library; an open squish's original or copy always stays). The removal goes through the QA gate (`qa_gate`, operation "remove from the QA album"). If there aren't enough iCloud-only items, nothing changes and the line says "refused". Then each file becomes a new asset with its original file name, added to the album in the same change after the album is looked up again; imported files are deleted from Documents, failed ones stay for the next try. `qa_restock` events (steps `start`, `room`, `imported`, `done`) record counts only, including how many imported assets kept a location (`withLocation`) and their file's date (`datedFromFile`).
- Unverified until it runs on the phone: the devicectl copy into `Documents/qa-restock/` (directory contents, as `qa_pull.sh` gets them the other way) and Photos taking the files' dates and locations (`withLocation`, `datedFromFile` will show it).
