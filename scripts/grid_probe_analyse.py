#!/usr/bin/env python3
"""Reads a scripts/grid_probe.sh movie and prints the interaction numbers
(docs/investigations/2026-11-27-grid-interactions.md).

Usage: python3 scripts/grid_probe_analyse.py <movie.mp4>                 (Make album grid)
       python3 scripts/grid_probe_analyse.py --duplicates <movie.mp4>    (a Duplicates group)
The movie is resampled to 60 fps at 1 px per point (402 x 874); the simulator records a frame whenever the screen
changes, so one frame is 16.7 ms while anything moves.

(a) Touch-down feedback, as "first visible change of the pressed cell, before the release". A tap selects on release,
    so the release is the frame the selection starts to show. AXe's hold is "0.5 s" but measured at about 0.8 s from
    down to up (the Duplicates press, which shows feedback at touch-down, leads its release by that much), so the
    number is a lead time: 0 ms = nothing happens until the finger lifts. A held press (1.5 s) must still select.
(b) Drag to select: per photo the drag passes (4, 5, 6), the frames its check spends between off and on: how long
    the selection trails the finger.
(c) Interruption: photo 7 tapped twice about 0.1 s apart (AXe's double tap). The fill must turn back from where it
    is, and the white tick must leave with it rather than pop out in one frame. In a Duplicates group (taps ~1 s
    apart: AXe runs one command per simulator at a time), a leaving Keep tag must fade like an arriving one does; one
    that goes in a single frame can't be caught by a tap straight after.
"""
import subprocess
import sys

import numpy as np

W, H, FPS = 402, 874, 60
X0, Y0, SIDE, STRIDE = 20.0, 281.3, 117.7, 121.7
BLUE_R = 0x2F  # Roll.Palette.album's red channel: the check's fill.
NOISE = 1.5  # mean absolute pixel difference that counts as a visible change (encoder noise is under 1)


def frames(path):
  cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf", f"fps={FPS},scale={W}:{H}", "-f", "rawvideo", "-pix_fmt",
         "rgb24", "-"]
  raw = subprocess.run(cmd, capture_output=True, check=True).stdout
  return np.frombuffer(raw, np.uint8).reshape(-1, H, W, 3).astype(np.float32)


def first(mask, start=0):
  idx = np.where(mask[start:])[0]
  return start + idx[0] if len(idx) else None


def cell(i):
  r, c = divmod(i, 3)
  x, y = X0 + c * STRIDE, Y0 + r * STRIDE
  return int(x), int(y), int(x + SIDE), int(y + SIDE)


def check_box(i, half):
  """A square around the centre of the 24 pt check circle (6 pt in from the cell's top-right corner)."""
  _, y0, x1, _ = cell(i)
  cx, cy = int(x1 - 18), int(y0 + 18)
  return cx - half, cy - half, cx + half, cy + half


def crop(v, box):
  x0, y0, x1, y1 = box
  return v[:, y0:y1, x0:x1]


def change(v, box):
  r = crop(v, box)
  return np.abs(r - r[0]).mean((1, 2, 3))


def album(path):
  v = frames(path)
  t = np.arange(len(v)) / FPS
  # Fill p: 0 = the check's first-frame colour (an empty ring over the photo), 1 = checked (photo 4 at the end).
  on = crop(v[-5:], check_box(3, 7)).mean((0, 1, 2))
  p = {}
  for i in range(9):
    c = crop(v, check_box(i, 7)).mean((1, 2))
    axis = on - c[0]
    p[i] = ((c - c[0]) @ axis) / max(axis @ axis, 1e-6)

  release = first(p[1] > 0.05)
  fb = first(change(v, cell(1)) > NOISE)
  if release is None:
    print(f"(a) photo 2, pressed then lifted: NOT selected (the press was dropped); "
          f"{'no visible feedback at all' if fb is None else f'a change at {t[fb]:.2f} s'}")
  else:
    print(f"(a) photo 2, pressed then lifted: first feedback {(release - fb) / FPS * 1000:.0f} ms before the "
          f"release (release at {t[release]:.2f} s)")
  print(f"(a) photo 3, held 1.5 s: {'selected' if p[2][-1] > 0.5 else 'NOT selected'} (fill at the end {p[2][-1]:.2f})")
  for i in (3, 4, 5):
    start = first(p[i] > 0.05)
    if start is None:
      print(f"(b) photo {i + 1}: never selected")
      continue
    between = int(((p[i][start:] > 0.05) & (p[i][start:] < 0.95))[:60].sum())
    print(f"(b) photo {i + 1}: check between off and on for {between} frame(s) ({between / FPS * 1000:.0f} ms)")

  f = p[6]
  start = first(f > 0.05)
  if start is None:
    print("(c) photo 7: never selected")
    return
  back = first(np.diff(f) < -0.05, start) + 1
  # Tick: how white the middle of the circle is above the plain fill (the album blue's red channel), relative to the
  # steady checked look (photo 4's middle at the end). The photo under an empty ring can be white too, so it is only
  # read while the fill is mostly on: around the second tap.
  red = crop(v, check_box(6, 3))[..., 0].mean((1, 2))
  red_on = crop(v[-5:], check_box(3, 3))[..., 0].mean()
  tick = (red - BLUE_R) / (red_on - BLUE_R)
  # A pop: a frame where the tick loses most of its whiteness while the fill hasn't moved yet (the "off" photo can be
  # white, so the tick is only read while the fill is still at 90% or more of the frame before).
  pops = [i for i in range(start + 1, len(f))
          if f[i] > 0.5 and f[i] >= 0.9 * f[i - 1] and tick[i] < 0.3 * tick[i - 1]]
  fill_gone = first(f < 0.05, back)
  print(f"(c) photo 7: second tap {(back - 1 - start) / FPS * 1000:.0f} ms after the first, fill turns back from "
        f"{f[back - 1]:.2f} and is off "
        f"{fill_gone - back + 1} frames later; tick pop frames (tick gone, fill still on): {len(pops)}; ends "
        f"{'off' if f[-1] < 0.5 else 'ON'}")
  print(f"    fill: {' '.join(f'{x:.2f}' for x in f[start - 1:back + 12])}")
  print(f"    tick: {' '.join(f'{x:.2f}' for x in np.clip(tick[start - 1:back + 12], -9, 9))}")


def duplicates(path):
  v = frames(path)
  left, right = (28, 161, 199, 332), (203, 161, 374, 332)

  def pill(box):
    """The Keep tag is a white pill in the shot's top-left corner: the share of near-white pixels there."""
    x0, y0, _, _ = box
    return (crop(v, (x0 + 6, y0 + 6, x0 + 76, y0 + 34)).min(3) > 235).mean((1, 2))

  # Events from the pill (robust timing): where the tag is fully there.
  lw, rw = pill(left), pill(right)
  lw, rw = lw / lw.max(), rw / rw.max()
  release = first(lw > 0.05)  # the Keep tag starts to arrive on the left: the press was lifted
  fb = first(change(v, left) > NOISE)
  print(f"(a) duplicates, left shot pressed then lifted: first feedback {(release - fb) / FPS * 1000:.0f} ms before "
        f"the Keep tag arrives (release)")
  settled = first(lw > 0.95, release) + 20

  # Shape from colour: the corner (tag, or ember dot) projected from "not kept" to "kept", 0 to 1, per shot. Left: not
  # kept in the first frame, kept once (a) settled; right: the other way round.
  def kept(box, off, on):
    x0, y0, _, _ = box
    c = crop(v, (x0 + 6, y0 + 6, x0 + 76, y0 + 34)).mean((1, 2))
    axis = c[on] - c[off]
    return ((c - c[off]) @ axis) / max(axis @ axis, 1e-6)

  lp, rp = kept(left, 0, settled), kept(right, settled, 0)

  def span(series, start, falling):
    """Frames from the first step away from the old value to the new one (5%-95%)."""
    s0 = first(series < 0.95 if falling else series > 0.05, start)
    s1 = first(series < 0.05 if falling else series > 0.95, s0)
    return s0, s1 - s0 + 1

  leave, left_out = span(lp, settled, True)
  _, right_in = span(rp, leave - 5, False)
  back = first(lp > 0.05, leave + left_out + 5)
  _, right_out = span(rp, back - 5, True)
  _, left_in = span(lp, back, False)
  print(f"(c) duplicates: tag leaving the left {left_out} frame(s), arriving on the right {right_in}; "
        f"then leaving the right {right_out}, arriving on the left {left_in}; the right starts "
        f"{(first(rp > 0.05, leave - 5) - leave) / FPS * 1000:.0f} ms after the left starts leaving")
  print(f"    left : {' '.join(f'{x:.2f}' for x in lp[leave - 2:leave + 14])}")
  print(f"    right: {' '.join(f'{x:.2f}' for x in rp[leave - 2:leave + 14])}")


if __name__ == "__main__":
  if sys.argv[1] == "--duplicates":
    duplicates(sys.argv[2])
  else:
    album(sys.argv[1])
