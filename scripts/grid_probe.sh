#!/usr/bin/env bash
# Measures the Make album grid against three interaction rules while the simulator screen is recorded
# (docs/investigations/2026-11-27-grid-interactions.md). Needs AXe (/opt/homebrew/bin/axe), a booted simulator with Roll
# installed and a seeded library (just seed-sim), and numpy. Analyse the movie with scripts/grid_probe_analyse.py.
# Usage: scripts/grid_probe.sh <udid> <out.mp4> [album|duplicates]
# duplicates: opens Home > Duplicates > the first group (the seed library has one pair) and presses its shots.
# Cell geometry is the iPhone 17 Pro's (402 pt wide): 3 columns of 117.7 pt, 4 pt apart, the first row at y 281.3.
set -euo pipefail
U=${1:?udid}
OUT=${2:?out.mp4}
MODE=${3:-album}

if [ "$MODE" = duplicates ]; then
  xcrun simctl launch --terminate-running-process "$U" com.delavalom.roll \
    -UITestSkipPaywall -onboardingComplete YES -UITestStubEmbedder >/dev/null
  for _ in $(seq 60); do sleep 1; axe tap --id home.card.duplicates --udid "$U" >/dev/null 2>&1 && break; done
  sleep 2
  axe tap --id duplicates.group --udid "$U" >/dev/null
  sleep 3
  xcrun simctl io "$U" recordVideo --codec=h264 --force "$OUT" &
  REC=$!
  sleep 2.5
  # (a) Hold the shot to delete (left, 28-199 x 161-332 pt) for 0.5 s: it becomes the keeper on release.
  axe touch -x 113 -y 246 --down --up --delay 0.5 --udid "$U" >/dev/null
  sleep 1.5
  # (c) Tap the right shot, then the left one: the Keep tag leaves one shot and arrives on the other, twice. (AXe runs
  # one command per simulator at a time, so these taps are ~0.5 s apart: the album double tap covers interrupting.)
  axe touch -x 288 -y 246 --down --up --delay 0.02 --udid "$U" >/dev/null
  sleep 1
  axe touch -x 113 -y 246 --down --up --delay 0.02 --udid "$U" >/dev/null
  sleep 1.5
  kill -INT $REC
  wait $REC || true
  echo "$OUT"
  exit 0
fi

xcrun simctl launch --terminate-running-process "$U" com.delavalom.roll \
  -UITestSkipPaywall -onboardingComplete YES -UITestStubEmbedder -UITestOpen album >/dev/null
# Wait for the grid: the "Add 0 photos" bar (y 721 pt) turns grey and the first photo is drawn.
SHOT=$(mktemp -t gridprobe).png
for _ in $(seq 60); do
  sleep 1
  xcrun simctl io "$U" screenshot "$SHOT" >/dev/null 2>&1 || continue
  python3 - "$SHOT" <<'PY' && break
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
bar, photo = im.getpixel((3 * 201, 3 * 721)), im.getpixel((3 * 40, 3 * 300))
grey = max(bar) - min(bar) < 12 and max(bar) < 225
sys.exit(0 if grey and sum(abs(a - b) for a, b in zip(photo, (246, 244, 239))) > 40 else 1)
PY
done
rm -f "$SHOT"
sleep 2

xcrun simctl io "$U" recordVideo --codec=h264 --force "$OUT" &
REC=$!
sleep 2.5

# (a) Touch-down feedback: hold photo 2 for 0.5 s, then lift (a tap toggles it on release). Then hold photo 3 for
# 1.5 s: a slow press should still select.
axe touch -x 200.5 -y 340.2 --down --up --delay 0.5 --udid "$U" >/dev/null
sleep 1.5
axe touch -x 322.2 -y 340.2 --down --up --delay 1.5 --udid "$U" >/dev/null
sleep 1.5
# (b) Drag to select: a slow sideways drag from photo 4 to photo 6 (2 s, a sample every 3 pt).
axe swipe --start-x 60 --start-y 461.8 --end-x 330 --end-y 461.8 --duration 2 --delta 3 --udid "$U" >/dev/null
sleep 1.5
# (c) Interruption: tap photo 7 twice, 80 ms apart, so the second tap lands while the first is still animating.
axe gesture double-tap -x 78.8 -y 583.5 --interval 0.08 --udid "$U" >/dev/null
sleep 1.5

kill -INT $REC
wait $REC || true
echo "$OUT"
