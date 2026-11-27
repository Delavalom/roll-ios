# Photo grid interaction audit (2026-11-27, for 1.2)

Three Apple interaction rules, checked on Roll's photo grids:

- (a) A cell answers at touch-down, not on release.
- (b) Drag-to-select stays under the finger with no lag.
- (c) Select/deselect animations can be interrupted and turned back mid-way.

The grids:
- Make album: `SelectableGrid` (tap and swipe to select).
- the Ask answer: `ResultGrid` (tap to open or pick).
- Duplicates: `DuplicatesView` groups and `DuplicateGroupView` shots (tap to pick the keeper).

## Method

Code reading first, then measurement on a simulator (Roll-Audit: iPhone 17 Pro, iOS 26.5, seeded library). I drove
it with AXe touches while `simctl io recordVideo` recorded the screen. `scripts/grid_probe.sh` drives a run and
`scripts/grid_probe_analyse.py` reads the movie:

- It resamples the movie to 60 fps at 1 px per point. The simulator writes a frame on every change, so one frame is
  16.7 ms while anything moves.
- For each cell it tracks two values:
  - "fill": how far the corner check has moved from off to on, from 0 to 1.
  - "change": the mean pixel difference from the first frame.

AXe's "0.5 s" hold measured about 0.8 s from down to up, and AXe runs one command per simulator at a time. So (a) is
measured as **how long before the release the first feedback appears**: 0 ms means nothing happens until the finger
lifts. The Duplicates press already shows feedback at touch-down, and it leads its release by 850–917 ms. For the
same reason, the Duplicates (c) check can't tap two shots 0.1 s apart. The album double tap (`axe gesture
double-tap --interval 0.08`) covers the interruption case.

Run it again:
- `scripts/grid_probe.sh <udid> out.mp4`, then `python3 scripts/grid_probe_analyse.py out.mp4`
- add `duplicates` to the probe and `--duplicates` to the analyser for a Duplicates group.

## Results

Two runs of the Make album grid before and after, one of a Duplicates group.

| Rule | Before | After | Verdict |
|---|---|---|---|
| (a) Make album: first feedback before the release | 0 ms (run 1); press dropped, no feedback (run 2) | 767 ms, 750 ms (at touch-down) | **Fixed** |
| (a) Make album: photo held 1.5 s | not selected (both runs) | selected (both runs) | **Fixed** (bug found by the probe) |
| (a) Ask answer grid (`ResultGrid`) | same `onTapGesture` cell as Make album | button with `PressScale` | **Fixed** (same change, not probed separately) |
| (a) Duplicates: first feedback before the release | 917 ms | 850 ms | Pass (already a `Button` + `PressScale`) |
| (b) Drag: frames each check spends between off and on (photos 4, 5, 6) | 2, 6, 7 and 2, 4, 7 (up to 117 ms behind the finger) | 0, 0, 0 and 0, 0, 0 | **Fixed** |
| (c) Make album: second tap 117–150 ms after the first | fill turns back and is off 7 frames later; 1 frame with the fill fully on and the tick gone (run 1) | fill turns back from 0.97, off 7 frames later; 0 such frames | **Fixed** (PickMark tick) |
| (c) Duplicates: Keep tag leaving / arriving | 6 / 7 frames, both ways | 6 / 7 frames | Pass (no change shipped) |

In run 2 before the fix, the tick and the fill changed in the same frame, so the pop counter shows 0 for that run.
Run 1 and the frame strip below show the pop.

![PickMark: before (top), a frame with the blue fill and no tick, then the fade; after (bottom), the tick fades with
the fill](2026-11-27-grid-interactions-pickmark.png)

## What was wrong and what changed

1. **Cells used `onTapGesture`**, in Make album and in the Ask answer grid. That gives no feedback until the finger
   lifts, and a press held past roughly half a second never fires at all. Each cell is now a `Button` with
   `PressScale`, the same style the Duplicates grids already use. It shrinks at touch-down and toggles on release,
   however long the press. Drag-select still works: once the pan starts it takes over the touch from the button,
   and the existing drag UI tests pass.
2. **Drag updates were animated.** `SelectableGrid` wrapped every index change in `withAnimation(Roll.Motion.quick)`
   (0.22 s ease). That put each check 2–7 frames behind the finger. Drag updates now apply with no animation. Taps
   still animate.
3. **PickMark's tick was inserted and removed with `if on`.** When a second tap turned a pick back mid-animation,
   the tick disappeared in one frame while the fill faded. The tick now stays in the view, and its opacity and
   scale follow `on`, so it reverses with the fill.

The Keep tag in `DuplicateGroupView` measured as a fade both ways (6–7 frames), so it is unchanged. The first read
said it "popped". That came from a near-white pixel threshold, which drops to zero as soon as the tag's opacity dips
below 1. The colour projection now used in the analyser doesn't have that problem.

## Tests

- New: `FindFlowTests.testSlowPressSelects`. It holds a Make album photo for 1.5 s and expects "1 of" selected.
  - On the old `SelectableGrid`: **fails** (`a 1.5 s press didn't select: 0 of 30 selected`).
  - On the fix: passes.
- Run on Roll-Audit after the fix, all passing:
  - `FindFlowTests`: `testSlowPressSelects`, `testDragSelectsAcrossTheGrid`, `testDragSelectAutoscrolls`,
    `testSearchMakeAlbumCreated`;
  - `AskFlowTests.testAskRefineSwipeAndUndo`.
- Not run: the RollCore unit tests (`just test`). This change touches only the app target. The app build is the
  type check.

## Not covered

- A physical device. Simulator frame timing is close to a device at 60 Hz, but a ProMotion phone draws at 120 Hz and
  wasn't measured.
- Squish, Swipefiles' card stack and the Taste scan grid. None of them is a selectable photo grid.
