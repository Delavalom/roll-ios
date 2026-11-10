#!/usr/bin/env python3
"""Builds the static legal/support site for https://roll.delavalom.com into site/public/.

Standard library only. Usage: python3 site/build.py

- /privacy and /terms are rendered from docs/legal/*.md (the source of truth): HTML comments (the DRAFT header and
  the maintainer notes) are dropped and the {{PLACEHOLDERS}} are filled from site/site.json. The wording is not
  otherwise changed.
- / and /support come from site/src/pages/*.html (body fragments with a two-line header: title, description).
- site/src/style.css and site/src/static/* are copied as they are.

The output is committed so the deploy needs no build step (Vercel serves site/public as plain static files).
"""

from __future__ import annotations

import html
import json
import re
import shutil
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
SRC = SITE / "src"
OUT = SITE / "public"

PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")


def fill(text: str, values: dict[str, str], where: str) -> str:
    def sub(m: re.Match[str]) -> str:
        key = m.group(1)
        if key not in values:
            sys.exit(f"{where}: no value for {{{{{key}}}}} in site/site.json")
        return values[key]

    return PLACEHOLDER.sub(sub, text)


# ---------------------------------------------------------------- markdown (the subset docs/legal uses)

URL = re.compile(r"https?://[^\s<>()]+[^\s<>().,;:!?]")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
BOLD = re.compile(r"\*\*(.+?)\*\*")


def inline(text: str) -> str:
    out = html.escape(text, quote=False)
    out = BOLD.sub(r"<strong>\1</strong>", out)

    def link(m: re.Match[str]) -> str:
        url = m.group(0)
        return f'<a href="{url}">{url}</a>'

    out = URL.sub(link, out)
    out = EMAIL.sub(lambda m: f'<a href="mailto:{m.group(0)}">{m.group(0)}</a>', out)
    return out


def slug(text: str) -> str:
    s = re.sub(r"^\d+\.\s*", "", text.lower())
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def markdown(md: str) -> tuple[str, str]:
    """Returns (h1 text, body html without the h1)."""
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    title = ""
    blocks: list[str] = []
    para: list[str] = []
    items: list[list[str]] = []

    def flush() -> None:
        nonlocal para, items
        if para:
            blocks.append(f"<p>{inline(' '.join(para))}</p>")
            para = []
        if items:
            lis = "".join(f"<li>{inline(' '.join(i))}</li>" for i in items)
            blocks.append(f"<ul>{lis}</ul>")
            items = []

    for raw in md.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush()
        elif line.startswith("# "):
            flush()
            title = line[2:].strip()
        elif line.startswith("## "):
            flush()
            text = line[3:].strip()
            blocks.append(f'<h2 id="{slug(text)}">{inline(text)}</h2>')
        elif line.startswith("- "):
            if para:
                flush()
            items.append([line[2:].strip()])
        elif items and raw.startswith("  "):
            items[-1].append(line.strip())
        else:
            if items:
                flush()
            para.append(line.strip())
    flush()
    return title, "\n".join(blocks)


# ---------------------------------------------------------------- pages


def page(layout: str, *, path: str, title: str, description: str, body: str, values: dict[str, str]) -> str:
    nav = []
    for href, label in (("/privacy", "Privacy"), ("/terms", "Terms"), ("/support", "Support")):
        current = ' aria-current="page"' if href == path else ""
        nav.append(f'<a href="{href}"{current}>{label}</a>')
    full_title = title if path == "/" else f"{title} · Roll"
    canonical = "" if path == "/404" else f'<link rel="canonical" href="{values["SITE_URL"]}{"" if path == "/" else path}">\n  '
    return fill(
        layout.replace("{{TITLE}}", html.escape(full_title))
        .replace("{{DESCRIPTION}}", html.escape(description))
        .replace("{{CANONICAL}}", canonical)
        .replace("{{NAV}}", "\n        ".join(nav))
        .replace("{{BODY}}", body),
        values,
        path,
    )


def main() -> None:
    values: dict[str, str] = json.loads((SITE / "site.json").read_text())
    layout = (SRC / "layout.html").read_text()

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir()

    legal = {  # name -> (page title, description)
        "privacy": ("Privacy Policy", "How Roll handles your information: photos are analyzed on your iPhone and never uploaded. No analytics, no tracking, no accounts."),
        "terms": ("Terms of Use", "Terms of Use for Roll and the one-time Roll Pro purchase, under Apple's Standard Licensed Application End User License Agreement."),
    }
    for name, (page_title, description) in legal.items():
        md = (REPO / "docs" / "legal" / f"{'privacy-policy' if name == 'privacy' else name}.md").read_text()
        title, body = markdown(fill(md, values, name))
        body = f'<article class="prose">\n<h1>{inline(title)}</h1>\n{body}\n</article>'
        out = page(layout, path=f"/{name}", title=page_title, description=description, body=body, values=values)
        (OUT / f"{name}.html").write_text(out)

    for src in sorted((SRC / "pages").glob("*.html")):
        title, description, body = src.read_text().split("\n", 2)
        path = "/" if src.stem == "index" else f"/{src.stem}"
        out = page(layout, path=path, title=title, description=description, body=body.strip(), values=values)
        (OUT / src.name).write_text(out)

    shutil.copy(SRC / "style.css", OUT / "style.css")
    for f in (SRC / "static").iterdir():
        shutil.copy(f, OUT / f.name)

    for f in OUT.glob("*.html"):
        if PLACEHOLDER.search(f.read_text()):
            sys.exit(f"unfilled placeholder in {f.name}")
    print("built", ", ".join(sorted(p.name for p in OUT.iterdir())))


if __name__ == "__main__":
    main()
