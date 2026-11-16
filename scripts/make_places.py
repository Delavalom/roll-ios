#!/usr/bin/env python3
"""Builds RollCore's offline gazetteer (`Packages/RollCore/Sources/Places/Resources/places.z`) from GeoNames.

GeoNames data is CC-BY 4.0 (https://www.geonames.org, attribution in `Sources/Places/Resources/NOTICE`). Roll never
geocodes over the network: this file is the only source of place names in the app.

Inputs (downloaded into --work, default a fresh temporary folder) from https://download.geonames.org/export/dump/:
  cities15000.zip        every populated place with at least 15,000 people (~32k kept: no city sections, no
                         historical or abandoned places)
  countryInfo.txt        country codes and names
  admin1CodesASCII.txt   first-level divisions (states, provinces, regions)
  alternateNamesV2.zip   only with --with-alternate-names (~200 MB): English and Spanish names for countries, first-level
                         divisions and cities of at least --alt-min-population people ("Nueva York", "Alemania")

Output: UTF-8 text, raw DEFLATE (RFC 1951, what Foundation's `NSData.decompressed(using: .zlib)` reads), three sections:
  #countries  code, iso3, name, alternates ("|"-separated)
  #admin1     "CC.code", name, ascii name, alternates
  #cities     name, ascii name, alternates, country code, admin1 code, lat, lon (4 decimals, ~11 m), population

Usage:  python3 -I scripts/make_places.py [--with-alternate-names] [--work DIR] [--out PATH]
"""

import argparse
import io
import os
import re
import sys
import tempfile
import unicodedata
import urllib.request
import zipfile
import zlib

BASE = "https://download.geonames.org/export/dump/"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "Packages", "RollCore", "Sources", "Places", "Resources", "places.z")

# Hand-written aliases people type that GeoNames doesn't tag as English or Spanish. Lowercase.
COUNTRY_ALIASES = {
    "US": ["usa", "united states of america", "eeuu", "ee uu"],
    "GB": ["uk", "great britain", "britain"],
    "AE": ["uae"],
    "DO": ["dominican republic", "republica dominicana"],
    "PR": ["puerto rico"],
}
MAX_ALTERNATES = 6
# Feature codes left out: sections of a populated place (Paris arrondissements, Berlin's Wedding, London's Soho: a
# photo there should be named after the city), and historical, abandoned or destroyed places.
SKIPPED_FEATURES = {"PPLX", "PPLH", "PPLQ", "PPLW", "PPLCH"}
# Numbered districts listed as places of their own ("Paris 16 Passy", "Marseille 08", "Seen (Kreis 3)").
NUMBERED_DISTRICT = re.compile(r"\b\d{1,2}\b")


def fold(text):
    """Lowercase ASCII-ish form, the way `Gazetteer` folds names (diacritics off, punctuation to spaces)."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    text = "".join(c if c.isalnum() else " " for c in text)
    return " ".join(text.split())


def download(name, work):
    path = os.path.join(work, name)
    if not os.path.exists(path):
        print(f"downloading {name}", file=sys.stderr)
        with urllib.request.urlopen(BASE + name) as response, open(path, "wb") as out:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                out.write(chunk)
    return path


def read_countries(path):
    countries = {}  # code -> dict
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            countries[cols[0]] = {"iso3": cols[1], "name": cols[4], "geonameid": cols[16] if len(cols) > 16 else ""}
    return countries


def read_admin1(path):
    admin1 = {}  # "CC.code" -> dict
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 4:
                continue
            admin1[cols[0]] = {"name": cols[1], "ascii": cols[2], "geonameid": cols[3]}
    return admin1


def read_cities(path):
    cities = []
    with zipfile.ZipFile(path) as z, z.open("cities15000.txt") as raw:
        for line in io.TextIOWrapper(raw, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if cols[7] in SKIPPED_FEATURES or NUMBERED_DISTRICT.search(cols[1]):
                continue
            cities.append({
                "geonameid": cols[0], "name": cols[1], "ascii": cols[2], "lat": float(cols[4]), "lon": float(cols[5]),
                "country": cols[8], "admin1": cols[10], "population": int(cols[14] or 0),
            })
    return cities


def read_alternates(path, wanted):
    """geonameid -> [names] in English or Spanish, preferred names first; colloquial and historic names left out."""
    found = {}
    with zipfile.ZipFile(path) as z, z.open("alternateNamesV2.txt") as raw:
        for line in io.TextIOWrapper(raw, encoding="utf-8"):
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 8 or cols[2] not in ("en", "es") or cols[1] not in wanted:
                continue
            if cols[6] == "1" or cols[7] == "1":  # colloquial, historic
                continue
            preferred = cols[4] == "1"
            found.setdefault(cols[1], []).append((0 if preferred else 1, cols[3]))
    return {k: [name for _, name in sorted(v)] for k, v in found.items()}


def alternates(names, *known):
    """Distinct folded alternates not already equal to a known name, at most MAX_ALTERNATES."""
    seen = {fold(k) for k in known if k}
    out = []
    for name in names:
        key = fold(name)
        if not key or key in seen or any(c.isdigit() for c in key) or len(key) < 3:
            continue
        seen.add(key)
        out.append(name.replace("|", " ").replace("\t", " "))
        if len(out) >= MAX_ALTERNATES:
            break
    return out


def clean(text):
    return text.replace("\t", " ").replace("\n", " ")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", help="download folder (default: a new temporary folder)")
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--with-alternate-names", action="store_true",
                        help="also download alternateNamesV2.zip (~200 MB) for English and Spanish names")
    parser.add_argument("--alt-min-population", type=int, default=500_000,
                        help="cities this big get English and Spanish alternate names")
    args = parser.parse_args()

    work = args.work or tempfile.mkdtemp(prefix="geonames-")
    os.makedirs(work, exist_ok=True)
    countries = read_countries(download("countryInfo.txt", work))
    admin1 = read_admin1(download("admin1CodesASCII.txt", work))
    cities = read_cities(download("cities15000.zip", work))

    alt = {}
    if args.with_alternate_names:
        wanted = {c["geonameid"] for c in countries.values() if c["geonameid"]}
        wanted |= {a["geonameid"] for a in admin1.values()}
        wanted |= {c["geonameid"] for c in cities if c["population"] >= args.alt_min_population}
        alt = read_alternates(download("alternateNamesV2.zip", work), wanted)

    lines = ["#countries"]
    for code in sorted(countries):
        c = countries[code]
        names = COUNTRY_ALIASES.get(code, []) + alt.get(c["geonameid"], [])
        lines.append("\t".join([code, c["iso3"], clean(c["name"]), "|".join(alternates(names, c["name"]))]))
    lines.append("#admin1")
    for key in sorted(admin1):
        a = admin1[key]
        lines.append("\t".join([key, clean(a["name"]), clean(a["ascii"]),
                                "|".join(alternates(alt.get(a["geonameid"], []), a["name"], a["ascii"]))]))
    lines.append("#cities")
    cities.sort(key=lambda c: (-c["population"], c["geonameid"]))
    for c in cities:
        names = alt.get(c["geonameid"], []) if c["population"] >= args.alt_min_population else []
        lines.append("\t".join([
            clean(c["name"]), clean(c["ascii"]), "|".join(alternates(names, c["name"], c["ascii"])), c["country"],
            c["admin1"], f"{c['lat']:.4f}", f"{c['lon']:.4f}", str(c["population"]),
        ]))
    text = ("\n".join(lines) + "\n").encode("utf-8")
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    data = compressor.compress(text) + compressor.flush()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(data)
    print(f"{len(countries)} countries, {len(admin1)} admin1, {len(cities)} cities; "
          f"{len(text):,} bytes of text, {len(data):,} compressed -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
