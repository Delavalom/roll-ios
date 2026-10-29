#!/usr/bin/env python3
"""Writes STATUS.md (gitignored) from docs/MILESTONES.md and the last RollCore test run, and prints it.

Test results are the JUnit XML files `swift test --parallel --xunit-output .build/test-results.xml` leaves in
Packages/RollCore/.build (`just test` does this): test-results.xml for XCTest and test-results-swift-testing.xml for
Swift Testing, each holding one <testsuite> per test process. Standard library only, so CI needs nothing extra.
"""
import collections
import datetime
import pathlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = ROOT / "Packages" / "RollCore" / ".build"
MILESTONE = re.compile(r"^- \[( |x)\] \*\*(M\d+[^*]*)\*\*")


def milestones():
    rows = []
    for line in (ROOT / "docs" / "MILESTONES.md").read_text().splitlines():
        m = MILESTONE.match(line)
        if m:
            rows.append((m.group(1) == "x", m.group(2).rstrip(". ")))
    return rows


def test_results():
    """Totals, per-module counts and failing tests from every results file, or None when there are none."""
    files = sorted(RESULTS.glob("test-results*.xml"))
    if not files:
        return None
    totals = collections.Counter()
    modules = collections.defaultdict(collections.Counter)
    failing = []
    newest = max(f.stat().st_mtime for f in files)
    for path in files:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as error:
            failing.append(f"{path.name}: unreadable ({error})")
            continue
        for case in root.iter("testcase"):
            module = case.get("classname", "").split(".")[0] or "?"
            outcome = "passed"
            if case.find("failure") is not None or case.find("error") is not None:
                outcome = "failed"
                failing.append(f"{case.get('classname')}.{case.get('name')}")
            elif case.find("skipped") is not None:
                outcome = "skipped"
            totals[outcome] += 1
            modules[module][outcome] += 1
    return {"totals": totals, "modules": modules, "failing": failing, "files": [f.name for f in files],
            "when": datetime.datetime.fromtimestamp(newest).strftime("%Y-%m-%d %H:%M")}


def git_head():
    try:
        return subprocess.run(["git", "-C", str(ROOT), "log", "-1", "--format=%h %s"], capture_output=True, text=True,
                              check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def render():
    rows = milestones()
    done = sum(1 for ok, _ in rows if ok)
    out = ["# Roll status", "", f"Generated {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')} at `{git_head()}`"
           " by `just status` (scripts/gen_status.py). Do not edit; it is regenerated.", "",
           f"## Milestones: {done} of {len(rows)} done", ""]
    out += [f"- [{'x' if ok else ' '}] {name}" for ok, name in rows]
    out += ["", "## RollCore tests", ""]
    results = test_results()
    if results is None:
        out.append("No results yet. Run `just test` (it writes Packages/RollCore/.build/test-results*.xml).")
    else:
        t = results["totals"]
        verdict = "failing" if t["failed"] else "passing"
        out.append(f"Last run {results['when']}: **{verdict}**, {t['passed']} passed, {t['failed']} failed, "
                   f"{t['skipped']} skipped ({sum(t.values())} tests).")
        out += ["", "| Module | Passed | Failed | Skipped |", "|---|---:|---:|---:|"]
        for module in sorted(results["modules"]):
            c = results["modules"][module]
            out.append(f"| {module} | {c['passed']} | {c['failed']} | {c['skipped']} |")
        if results["failing"]:
            out += ["", "Failing:", ""] + [f"- `{name}`" for name in results["failing"][:30]]
    return "\n".join(out) + "\n"


def main():
    text = render()
    (ROOT / "STATUS.md").write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
