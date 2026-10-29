#!/usr/bin/env python3
"""Builds the seeded simulator's library in artifacts/seed/ (Task 14).

60 fixtures from ../embeddinggemma-coreml/fixtures/images (screenshots, memes, blurry, near-duplicates, receipts and
ordinary photos), plus generated items Roll's other screens need:
- 3 MOVs from ffmpeg's testsrc, 1080p30 H.264 at a high bitrate: two 8 s clips (Squish candidates by bitrate) and one
  45 s clip (also a "big video": Roll estimates 1080p30 at 10 Mbps, so 45 s is about 56 MB, over the 50 MB line);
- 1 large JPEG (12 MP), so Squish has a photo to offer (JPEG over 3 MB).

Screenshots are re-saved as PNG with the EXIF UserComment "Screenshot" (scripts/tag_screenshots.swift, through
ImageIO like iOS's own screenshots), the marker Photos uses for the photoScreenshot subtype; without it Roll's
Screenshots pile would be empty.

Needs Pillow, ffmpeg (brew install ffmpeg) and the Swift toolchain. Deterministic: the same fixtures in the same order
every run.
"""
import json
import pathlib
import shutil
import subprocess
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT.parent / "embeddinggemma-coreml" / "fixtures"
OUT = ROOT / "artifacts" / "seed"

# category -> how many (60 in total). "photos" draws evenly from the ordinary categories.
PICKS = {"screenshots": 12, "memes": 8, "blurry": 8, "near_duplicates": 10, "receipts": 6}
PHOTO_CATEGORIES = ["people", "dogs", "cats", "food", "landscapes", "buildings", "cars", "documents"]
PHOTOS_EACH = 2



def fixtures_by_category():
    rows = [json.loads(line) for line in (FIXTURES / "images.jsonl").read_text().splitlines() if line.strip()]
    by = {}
    for row in sorted(rows, key=lambda r: r["id"]):
        by.setdefault(row["category"], []).append(FIXTURES / row["file"])
    return by


def tag_screenshots(pairs):
    """One Swift run for all of them (ImageIO writes the EXIF UserComment Photos reads)."""
    args = [str(p) for pair in pairs for p in pair]
    subprocess.run(["xcrun", "swift", str(ROOT / "scripts" / "tag_screenshots.swift"), *args], check=True)


def make_videos():
    if shutil.which("ffmpeg") is None:
        sys.exit("ffmpeg is missing: brew install ffmpeg")
    for name, seconds in [("video_8s_a", 8), ("video_8s_b", 8), ("video_45s", 45)]:
        dst = OUT / f"{name}.mov"
        pattern = "testsrc2" if name.endswith("b") else "testsrc"
        # Constant 20 Mbps so the file really is large (testsrc alone compresses to almost nothing).
        subprocess.run([
            "ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"{pattern}=size=1920x1080:rate=30:duration={seconds}",
            "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-b:v", "20M", "-minrate", "20M",
            "-maxrate", "20M", "-bufsize", "20M", "-x264-params", "nal-hrd=cbr", "-movflags", "+faststart", str(dst),
        ], check=True)


def make_large_jpeg(source: pathlib.Path):
    image = Image.open(source).convert("RGB").resize((4032, 3024), Image.LANCZOS)
    image.save(OUT / "photo_12mp.jpg", format="JPEG", quality=95)


def main():
    if not FIXTURES.exists():
        sys.exit(f"fixtures not found at {FIXTURES} (embeddinggemma-coreml must sit next to this repo)")
    by = fixtures_by_category()
    picks = []
    for category, count in PICKS.items():
        files = by.get(category, [])
        if len(files) < count:
            sys.exit(f"only {len(files)} {category} fixtures, need {count}")
        picks += [(category, f) for f in files[:count]]
    for category in PHOTO_CATEGORIES:
        picks += [("photos", f) for f in by.get(category, [])[:PHOTOS_EACH]]
    if len(picks) != 60:
        sys.exit(f"picked {len(picks)} fixtures, expected 60")

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    screenshots = []
    for category, src in picks:
        dst = OUT / f"{category}_{src.name}"
        if category == "screenshots":
            screenshots.append((src, dst.with_suffix(".png")))
        else:
            shutil.copyfile(src, dst)
    tag_screenshots(screenshots)
    make_large_jpeg(by["landscapes"][-1])
    make_videos()
    print(f"{len(list(OUT.iterdir()))} files in {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
