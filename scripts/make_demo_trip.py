#!/usr/bin/env python3
"""Builds a demo trip for the Roll-Demo simulator's library in artifacts/demo-trip/out/ (App Store screenshots and
demo videos for Find; never the founder's photos).

48 CC0 photos of Lisbon from Wikimedia Commons (one photographer's walk; sources and authors in
scripts/demo_trip_sources.json), re-dated as a three-day trip, 10-12 May 2024, with GPS positions in Lisbon, so a
query like "Lisbon 2024" finds them through the offline gazetteer and Find groups them by day. The dates and positions
are made up for the demo; the pictures are real.

Downloads the 1600 px Commons thumbnails once (politely, one at a time) into artifacts/demo-trip/raw/, then writes
the date and GPS through ImageIO (scripts/stamp_photo.swift). Add them to the simulator with
    xcrun simctl addmedia Roll-Demo artifacts/demo-trip/out/*.jpg
Deterministic: same photos, same dates and positions every run. Needs curl and the Swift toolchain.
"""
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "scripts" / "demo_trip_sources.json"
RAW = ROOT / "artifacts" / "demo-trip" / "raw"
OUT = ROOT / "artifacts" / "demo-trip" / "out"

# (first photo number, date, start time, minutes between photos, latitude, longitude): one block per stretch of the walk.
DAYS = [
    (0, "2024:05:10", (9, 40), 11, 38.7115, -9.1305),    # Alfama and Baixa streets
    (28, "2024:05:11", (10, 15), 13, 38.7290, -9.1800),  # viewpoints over the river and the park
    (79, "2024:05:12", (18, 20), 9, 38.7135, -9.1335),   # back by the castle at dusk
]


def plan_for(number: int, index_in_day: int):
    day = max(d for d in DAYS if number >= d[0])
    _, date, (h, m), step, lat, lon = day
    minutes = h * 60 + m + index_in_day * step
    # Small, fixed spread so the photos aren't all on one point (about 100-300 m).
    jitter = ((number * 37) % 11 - 5) * 0.0004, ((number * 53) % 13 - 6) * 0.0004
    return f"{date} {minutes // 60:02d}:{minutes % 60:02d}:{number % 60:02d}", "+01:00", lat + jitter[0], lon + jitter[1]


def main():
    manifest = json.loads(SOURCES.read_text())
    sources = [{"file": p["file"], "download_url": manifest["file_base"] + p["path"]} for p in manifest["photos"]]
    RAW.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    for s in sources:
        f = RAW / s["file"]
        if not f.exists() or f.read_bytes()[:2] != b"\xff\xd8":
            subprocess.run(["curl", "-sf", "-A", "roll-demo-seed/1.0", "-o", str(f), s["download_url"]], check=True)
            time.sleep(1.5)
    lines, counts = [], {}
    for s in sorted(sources, key=lambda s: s["file"]):
        number = int(s["file"].split("_")[1].split(".")[0])
        day = max(d[0] for d in DAYS if number >= d[0])
        counts[day] = counts.get(day, -1) + 1
        when, offset, lat, lon = plan_for(number, counts[day])
        lines.append("\t".join([str(RAW / s["file"]), str(OUT / s["file"]), when, offset, f"{lat:.6f}", f"{lon:.6f}"]))
    plan = OUT / "plan.tsv"
    plan.write_text("\n".join(lines) + "\n")
    subprocess.run(["swift", str(ROOT / "scripts" / "stamp_photo.swift"), str(plan)], check=True)
    plan.unlink()
    print(f"{len(lines)} photos in {OUT}")


if __name__ == "__main__":
    main()
