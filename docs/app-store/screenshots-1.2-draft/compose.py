"""Composes DRAFT first three App Store screenshots for Roll 1.2 (6.9" set, 1320x2868, APP_IPHONE_67). Not uploaded.

Usage: python3 docs/app-store/screenshots-1.2-draft/compose.py
Reads raw/ (iPhone 17 Pro simulator captures, 1206x2622, 9:41 status bar) and writes 01.png-03.png, sheet.jpg (the
three side by side) and search-preview.png (the size they show in App Store search results) next to this file.

Captures (2026-11-27, Roll-Audit simulator, Roll 1.2 source, real EmbeddingGemma 2 model): the seeded QA library
(artifacts/seed: CC0 fixtures) plus the CC0 Lisbon demo trip (scripts/make_demo_trip.py), with four trip photos added
a second time so Duplicates finds real pairs. Never anyone's own photos.
- home.png: Home after indexing (122 items, about 116.5 MB to free).
- find-dark.png: Ask "Lisbon 2024" in dark mode, the real model's answer grouped by day. Its status line ("Compared 122
  items ... in 1.27 s") is a simulator time on a Mac, not a phone measurement.
- dup-list.png: Duplicates, 5 groups of real pairs.

Rules (founder, ~/.claude/rules/no-slop-edits.md and the 2026-11-27 brief): 2-4 word headlines with one key word in
colour, no italics; a loud full-bleed colour block on screen 1; the Find screen dark; the phone straight, nothing
breaking out of it, no drop shadow. No proof line: there is no rating or count we can stand behind yet.
"""
import pathlib

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
W, H = 1320, 2868
PAPER = (0xF6, 0xF4, 0xEF)
INK = (0x14, 0x14, 0x14)
EMBER = (0xFF, 0x5A, 0x36)
WHITE = (0xFF, 0xFF, 0xFF)
NIGHT = (0x0B, 0x0B, 0x0B)  # a shade under the app's dark page, so the phone's edge still reads
GRAPHITE = (0x3A, 0x39, 0x36)  # the phone's frame on the dark field

# (raw capture, field, frame colour, headline lines: (font size px, [(text, colour), ...])).
# Problem-led, answered: camera roll full -> cleared; can't find a photo -> find that photo; duplicates -> gone.
# Where the key word ends the headline it gets its own, larger line.
FRAMES = [
    ("home.png", EMBER, INK, [(180, [("Camera roll,", INK)]), (290, [("cleared.", WHITE)])]),
    ("find-dark.png", NIGHT, GRAPHITE, [(236, [("Find ", WHITE), ("that", EMBER)]), (236, [("photo.", WHITE)])]),
    ("dup-list.png", PAPER, INK, [(180, [("Duplicates,", INK)]), (290, [("gone.", EMBER)])]),
]

MARGIN = 80  # no headline line comes closer than this to the frame's sides
TOP = 150
PHONE_W = 1060  # outer width of the phone; it runs off the bottom edge of the frame
BEZEL = 22
SCREEN_RADIUS = 150


def font(size):
  f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
  f.set_variation_by_name("Black")
  return f


def headline(d, lines, y):
  for size, line in lines:
    f = font(size)
    width = sum(d.textlength(text, font=f) for text, _ in line)
    assert width <= W - 2 * MARGIN, f"{line} is {width:.0f} px wide"
    x = (W - width) / 2
    for text, colour in line:
      d.text((x, y), text, font=f, fill=colour)
      x += d.textlength(text, font=f)
    y += round(size * 1.02)
  return y


def phone(im, shot, frame_colour, top):
  """A plain, straight phone: a solid frame and the screen inside it, no tilt, no shadow."""
  sw = PHONE_W - 2 * BEZEL
  sh = round(shot.height * sw / shot.width)
  screen = shot.resize((sw, sh), Image.LANCZOS)
  x = (W - PHONE_W) // 2
  d = ImageDraw.Draw(im)
  d.rounded_rectangle((x, top, x + PHONE_W, top + sh + 2 * BEZEL), SCREEN_RADIUS + BEZEL, fill=frame_colour)
  mask = Image.new("L", (sw, sh), 0)
  ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), SCREEN_RADIUS, fill=255)
  im.paste(screen, (x + BEZEL, top + BEZEL), mask)
  # The Dynamic Island (125 x 37 pt, 11 pt from the top of a 402 pt screen): not every capture has it drawn.
  k = sw / 402
  iw, ih, it = 125 * k, 37 * k, 11 * k
  ix = x + BEZEL + (sw - iw) / 2
  d.rounded_rectangle((ix, top + BEZEL + it, ix + iw, top + BEZEL + it + ih), ih / 2, fill=(0, 0, 0))


def compose():
  out = []
  for n, (src, field, frame_colour, lines) in enumerate(FRAMES, 1):
    im = Image.new("RGB", (W, H), field)
    d = ImageDraw.Draw(im)
    y = headline(d, lines, TOP)
    shot = Image.open(HERE / "raw" / src).convert("RGB")
    phone(im, shot, frame_colour, y + 90)
    path = HERE / f"{n:02d}.png"
    im.save(path)
    out.append(im)
    print(path.name, im.size)
  strip = Image.new("RGB", (W * len(out) + 40 * (len(out) - 1), H), (0xDD, 0xDA, 0xD3))
  for i, im in enumerate(out):
    strip.paste(im, (i * (W + 40), 0))
  strip.resize((strip.width * 900 // H, 900), Image.LANCZOS).save(HERE / "sheet.jpg", quality=88)
  search = Image.new("RGB", (3 * 150 + 2 * 8, round(H * 150 / W)), WHITE)
  for i, im in enumerate(out):
    search.paste(im.resize((150, round(H * 150 / W)), Image.LANCZOS), (i * 158, 0))
  search.save(HERE / "search-preview.png")


if __name__ == "__main__":
  compose()
