#!/usr/bin/env bash
# Device QA (docs/qa/device-2026-10-23.md): stages the restock files for the "Roll QA" album on the phone. Builds them
# with scripts/make_qa_restock_media.py if any is missing, then copies artifacts/qa/restock/* into Roll's
# Documents/qa-restock/. Nothing is imported until Roll is launched with -QAAlbum "Roll QA" -QARestock
# (testD00RestockAlbum), which also deletes the copied files once they are in Photos.
#   scripts/qa_restock.sh <udid>
set -euo pipefail
udid="${1:?usage: qa_restock.sh <udid>}"
cd "$(dirname "$0")/.."
src=artifacts/qa/restock
expected=(restock_photo_a.jpg restock_photo_b.jpg restock_photo_c.png restock_video_8s.mov restock_video_45s.mov)
for f in "${expected[@]}"; do
  if [ ! -s "$src/$f" ]; then python3 scripts/make_qa_restock_media.py; break; fi
done
xcrun devicectl device copy to --device "$udid" --domain-type appDataContainer --domain-identifier com.delavalom.roll \
  --source "$src" --destination Documents/qa-restock >/dev/null
echo "staged on the phone: $(ls "$src" | tr '\n' ' ')"
echo "next: the destructive tests (testD00RestockAlbum runs first and imports them)"
