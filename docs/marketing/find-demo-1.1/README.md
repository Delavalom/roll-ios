# Roll 1.1 demo video: Clear + Find (DRAFT, 2026-11-16)

`roll-find-demo-1.1.mp4`: 37.9 s, 1080×1920, 30 fps, H.264 + AAC, music bed only (no voice). Captions are burned in;
`.srt` alongside. **Not posted anywhere.** Posting needs the founder's OK.

## What it shows

| Output | Picture | Caption |
|---|---|---|
| 0–8.6 s | Home → type "Lisbon 2024" ("Demo library · Recorded on the iOS Simulator" super) | CAN'T FIND THE TRIP? / JUST TYPE IT |
| 8.6–17 s | The answer: Lisbon 2024 · 29 photos, by day (12 May · 1, 10 May · 17, Buraca · 11 May · 11) | THE WHOLE TRIP / DAY BY DAY |
| 17–27 s | Make album → 29 of 29 → "Added 29 photos to “Lisbon, May 2024”" → Keep this album updated | MAKE THE ALBUM / NEW PHOTOS? ROLL ASKS FIRST |
| 27–37.9 s | Home → Blurry pile: swipe left (queued, not deleted), right (keep); Roll store card | THEN CLEAR SPACE / SWIPE. YOU DECIDE |

The answer's status line reads "Compared 224 items on this iPhone in 0.04 s": a simulator time on a Mac, which the
super labels. Don't quote it as a phone number (ADR-0002). No "Make a video" (memory videos are off in Release; the
recording used `-UITestReleaseFeatures`).

## Provenance

- Footage: Roll-Demo simulator, demo library only (200 CC0 fixtures + the CC0 Lisbon trip from
  `scripts/make_demo_trip.py`). Recorded by the factory playbook test `playbooks/mobile/demo/roll/FindDemoTests.swift`
  (`testFindShowcase`, `DEMO_ALBUM_NAME="Lisbon, May 2024"` because an earlier take had made "Lisbon 2024").
- Edit: Edit Studio project `projects/roll-find-demo` (brand delavalom-paper, reels track, reframe off, bold-caps
  captions from `captions.script.json`, lower-third + store-card, music `docs/design/ask-roll/video/music-bed.mp3`).
  The source was conformed to 30 fps CFR with `es media conform`, and the bed level used the silent-render fix; both
  are on Edit Studio branch `feat/media-conform`.
- `es verify` v4: ok, 0 problems, 1 warning. 1137/1137 frames; **−14.3 LUFS integrated, −1.4 dBTP true peak**;
  stills, overlap, duration, captions, text-hold, caption lines ≤ 2, text collision, flash, clip-source, track gaps,
  colour (SDR bt709) all ok. Warning: the store card's subtitle renders at 33 px (target 44, fail < 24), the shared
  format's own size, accepted.
- `es review` round 1 of 2: 0 errors, 1 warning (the same); nothing left to fix. Needs a listening pass by a human.
