"""Composes Roll 1.1's App Store screenshots (6.9" set, 1320x2868, APP_IPHONE_67) from Roll-Demo simulator shots.

Usage: python3 docs/app-store/screenshots-1.1/compose.py <shots-dir>
<shots-dir> holds the PNGs FindDemoTests writes (brand-studio factory playbooks/mobile/demo/roll/record-find.sh,
ROLL_SHOTS). The library is the CC0 demo library (fixtures + the Lisbon demo trip), never anyone's own photos.
Writes 01.png-05.png next to this file. Same canvas, fonts and colours as screenshots-1.0/compose.py.
The 1.1 set (2026-11-16) used f2-top, c0-home and c-blurry-swipe from the recorded take and f3-make-album and
f5-kept-updated from the first take, whose album is named "Lisbon 2024" like the query. 01 shows the app's own status
line ("Compared 224 items ... 0.04 s"): a simulator time on a Mac, not a phone measurement.
"""
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
W, H = 1320, 2868
PAPER = (0xF6, 0xF4, 0xEF)
INK = (0x14, 0x14, 0x14)
INK2 = (0x6E, 0x6A, 0x62)
EMBER = (0xFF, 0x5A, 0x36)

# (shot, headline line 1, accent line 2, subline). Find first (positioning doc §4): the trip, the album, kept updated;
# then Clear and the privacy line. Numbers only as the screen itself shows them.
SHOTS = [
    ("f2-top.png", "Find the trip", "in one sentence.", "“Lisbon 2024”: the whole trip, day by day."),
    ("f3-make-album.png", "One trip,", "one album.", "Pick what goes in. Albums are free."),
    ("f5-kept-updated.png", "New photos?", "Roll asks first.", "It offers matches. Nothing is added without you."),
    ("c0-home.png", "Get your space", "back.", "Screenshots, blurry shots, duplicates, big videos."),
    ("c-blurry-swipe.png", "Nothing leaves", "your iPhone.", "On-device AI. No upload, no account. Pay once."),
]


def font(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def compose(shots: pathlib.Path):
    for n, (src, l1, l2, sub) in enumerate(SHOTS, 1):
        im = Image.new("RGB", (W, H), PAPER)
        d = ImageDraw.Draw(im)
        hf, sf = font(112, "Bold"), font(50, "Regular")
        y = 150
        d.text((W // 2, y), l1, font=hf, fill=INK, anchor="ma")
        y += 132
        if l2:
            d.text((W // 2, y), l2, font=hf, fill=EMBER, anchor="ma")
            y += 132
        y += 24
        d.text((W // 2, y), sub, font=sf, fill=INK2, anchor="ma")
        top = y + 110
        sh = Image.open(shots / src).convert("RGB")
        h = H - top - 90
        w = round(sh.width * h / sh.height)
        sh = sh.resize((w, h), Image.LANCZOS)
        r = 78
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), r, fill=255)
        x = (W - w) // 2
        shadow = Image.new("L", (W, H), 0)
        ImageDraw.Draw(shadow).rounded_rectangle((x, top + 18, x + w, top + h + 18), r, fill=70)
        shadow = shadow.filter(ImageFilter.GaussianBlur(36))
        im.paste(Image.new("RGB", (W, H), (0, 0, 0)), (0, 0), shadow)
        ImageDraw.Draw(im).rounded_rectangle((x - 6, top - 6, x + w + 5, top + h + 5), r + 6, fill=(0xE4, 0xE0, 0xD8))
        im.paste(sh, (x, top), mask)
        out = HERE / f"{n:02d}.png"
        im.save(out)
        print(out.name, im.size, (w, h), top)


if __name__ == "__main__":
    compose(pathlib.Path(sys.argv[1]))
