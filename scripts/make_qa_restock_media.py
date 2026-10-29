#!/usr/bin/env python3
"""Builds the files that restock the device-QA album "Roll QA" (docs/qa/device-2026-10-23.md) in artifacts/qa/restock/.

Squish needs originals stored on the iPhone, and the founder's library is almost all iCloud-only, so these are made
on the Mac, copied into Roll's Documents/qa-restock/ (scripts/qa_restock.sh) and imported by a DEBUG `-QARestock`
launch (testD00RestockAlbum). Each one is a Squish candidate that should save at least 30%:
- 2 JPEGs, 12 MP (4032x3024), quality 97, from the embedding fixtures upscaled with a little film grain so they are
  real photos rather than flat colour (over 3 MB each). The first has an EXIF date and GPS position (Paris).
- 1 PNG photo, 2400x1800, not a screenshot (no "Screenshot" UserComment, not a screen size), over 3 MB.
- 2 MOVs, 1080p30 H.264 at a constant 20 Mbps from ffmpeg's testsrc with grain: 8 s (Squish by bitrate) and 45 s
  (also a "big video", over 50 MB), each with a QuickTime creation date and location.

Needs Pillow and ffmpeg (brew install ffmpeg). Deterministic: the same fixtures, the same seeded noise and the same
ffmpeg settings every run.
"""
import json
import pathlib
import random
import shutil
import subprocess
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT.parent / "embeddinggemma-coreml" / "fixtures"
OUT = ROOT / "artifacts" / "qa" / "restock"

# Fixed metadata, so survival after a squish can be checked (dates within 1 s, location within 1e-4 degrees).
PHOTO_DATE = "2025:05:04 10:20:30"
VIDEO_DATE = "2025-05-04T10:20:30+0200"
VIDEO_DATE_UTC = "2025-05-04T08:20:30Z"  # the movie header's creation_time (ffmpeg wants UTC here)
LATITUDE, LONGITUDE = 48.858370, 2.294481


def fixtures_by_category():
    rows = [json.loads(line) for line in (FIXTURES / "images.jsonl").read_text().splitlines() if line.strip()]
    by = {}
    for row in sorted(rows, key=lambda r: r["id"]):
        by.setdefault(row["category"], []).append(FIXTURES / row["file"])
    return by


def grainy(source: pathlib.Path, size, seed: int) -> Image.Image:
    """The fixture upscaled to `size` with about ±7 levels of seeded noise (an upscale alone compresses like a flat
    image, so the JPEG would stay under 3 MB)."""
    image = Image.open(source).convert("RGB").resize(size, Image.LANCZOS)
    noise = Image.frombytes("RGB", size, random.Random(seed).randbytes(size[0] * size[1] * 3))
    return Image.blend(image, noise, 0.055)


def dms(value: float):
    """Degrees, minutes, seconds as EXIF rationals."""
    value = abs(value)
    degrees = int(value)
    minutes = int((value - degrees) * 60)
    seconds = round(((value - degrees) * 60 - minutes) * 60, 4)
    return (degrees, minutes, seconds)


def exif_with_date_and_gps() -> Image.Exif:
    exif = Image.Exif()
    exif[0x0132] = PHOTO_DATE  # DateTime
    ifd = exif.get_ifd(0x8769)  # Exif IFD
    ifd[0x9003] = PHOTO_DATE  # DateTimeOriginal
    ifd[0x9004] = PHOTO_DATE  # DateTimeDigitized
    ifd[0x9011] = "+02:00"  # OffsetTimeOriginal
    gps = exif.get_ifd(0x8825)  # GPS IFD
    gps[0] = b"\x02\x03\x00\x00"  # GPSVersionID 2.3
    gps[1] = "N" if LATITUDE >= 0 else "S"
    gps[2] = dms(LATITUDE)
    gps[3] = "E" if LONGITUDE >= 0 else "W"
    gps[4] = dms(LONGITUDE)
    return exif


def make_photos(by):
    a = grainy(by["landscapes"][0], (4032, 3024), seed=1)
    a.save(OUT / "restock_photo_a.jpg", format="JPEG", quality=97, exif=exif_with_date_and_gps())
    b = grainy(by["buildings"][0], (4032, 3024), seed=2)
    b.save(OUT / "restock_photo_b.jpg", format="JPEG", quality=97)
    png = grainy(by["food"][0], (2400, 1800), seed=3)
    png.save(OUT / "restock_photo_c.png", format="PNG", optimize=False)


def make_videos():
    if shutil.which("ffmpeg") is None:
        sys.exit("ffmpeg is missing: brew install ffmpeg")
    iso6709 = f"{LATITUDE:+08.4f}{LONGITUDE:+09.4f}+035.000/"
    for name, seconds, pattern in [("restock_video_8s", 8, "testsrc2"), ("restock_video_45s", 45, "testsrc")]:
        # Constant 20 Mbps so the file really is large; the grain keeps the HEVC encode from being trivial.
        subprocess.run([
            "ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
            "-i", f"{pattern}=size=1920x1080:rate=30:duration={seconds}",
            "-vf", "noise=alls=8:allf=t:all_seed=7",
            "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-b:v", "20M", "-minrate", "20M",
            "-maxrate", "20M", "-bufsize", "20M", "-x264-params", "nal-hrd=cbr",
            "-metadata", f"creation_time={VIDEO_DATE_UTC}",
            "-metadata", f"com.apple.quicktime.creationdate={VIDEO_DATE}",
            "-metadata", f"com.apple.quicktime.location.ISO6709={iso6709}",
            "-movflags", "+faststart+use_metadata_tags", str(OUT / f"{name}.mov"),
        ], check=True)


def main():
    if not FIXTURES.exists():
        sys.exit(f"fixtures not found at {FIXTURES} (embeddinggemma-coreml must sit next to this repo)")
    by = fixtures_by_category()
    for category in ["landscapes", "buildings", "food"]:
        if not by.get(category):
            sys.exit(f"no {category} fixtures")
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    make_photos(by)
    make_videos()
    for f in sorted(OUT.iterdir()):
        print(f"{f.relative_to(ROOT)}  {f.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
