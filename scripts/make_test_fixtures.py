#!/usr/bin/env python3
"""Build the small image fixtures used by Packages/RollCore/Tests/SignalsTests.

Source: the embeddinggemma-coreml pipeline fixtures (CC0 / public domain images, generated
blurs and near-duplicates). Everything is downscaled so the committed set stays under 300 KB.

    python3 scripts/make_test_fixtures.py [SOURCE_DIR]

Output names are what the tests load:
    sharp_a.jpg  sharp_b.jpg      sharp photos (buildings, architecture detail)
    blurry_a.jpg blurry_b.jpg     Gaussian-blurred copies of sharp_a / sharp_b (from the pipeline)
    screenshot.png                synthetic phone screenshot (white background, text rows)
    dup_a.jpg   dup_b.jpg         near-duplicate pair (about 5% crop, JPEG re-encode)
    unrelated.jpg                 a different scene, for "unrelated pair" distances
"""
import sys
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
# Default: the sibling embeddinggemma-coreml checkout (see AGENTS.md); pass another folder to override.
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO.parent / "embeddinggemma-coreml/fixtures/images"
OUT = REPO / "Packages/RollCore/Tests/SignalsTests/Resources"
OUT.mkdir(parents=True, exist_ok=True)

# (output name, source stem prefix, max side, jpeg quality)
PICKS = [
    ("sharp_a.jpg", "i065_", 448, 72),
    ("blurry_a.jpg", "i154_", 448, 72),     # blur of i065
    ("sharp_b.jpg", "i020_", 448, 72),
    ("blurry_b.jpg", "i167_", 448, 72),     # blur of i020
    ("dup_a.jpg", "i093_", 448, 72),
    ("dup_b.jpg", "i180_", 448, 72),        # near-duplicate of i093
    ("unrelated.jpg", "i051_", 448, 72),
]


def find(prefix: str) -> Path:
    hits = sorted(SRC.glob(prefix + "*"))
    if not hits:
        sys.exit(f"missing source {prefix}* in {SRC}")
    return hits[0]


for name, prefix, side, quality in PICKS:
    im = Image.open(find(prefix)).convert("RGB")
    im.thumbnail((side, side), Image.LANCZOS)
    im.save(OUT / name, quality=quality, optimize=True)

shot = Image.open(find("i100_")).convert("RGB")
shot.thumbnail((390, 844), Image.LANCZOS)
shot.save(OUT / "screenshot.png", optimize=True)

total = 0
for p in sorted(OUT.iterdir()):
    total += p.stat().st_size
    print(f"{p.name:16s} {Image.open(p).size} {p.stat().st_size:7d} B")
print("total", total, "B")
