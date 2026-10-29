"""Regenerates this folder's extracts from Roll's raw QA log (identifier-free events only).

    python3 extract.py ~/egcm-evidence-raw/2026-10-29/roll-search-piles/qa/metrics.jsonl .

The run: build 814ad93 installed over the 30k proof build (data kept), launched 14:05:41 AST (t >= T0) with
`-QAMetrics -QASearchBench`. The typed queries are the bench's fixed strings (`QASearchBench.runTyped`), not the
founder's.
"""
import json
import os
import statistics as st
import sys

T0 = 1793297141
TIMELINE = ("session", "library_totals", "model", "thermal", "sync_read", "index_run", "text_pass", "locality_scan",
            "search_bench")


def main(raw: str, out: str) -> None:
    ev = [json.loads(line) for line in open(raw) if line.strip()]
    ev = [e for e in ev if e.get("t", 0) >= T0]

    def strip(e):
        return {k: v for k, v in e.items() if k != "t"}

    def dump(name, rows):
        with open(os.path.join(out, name), "w") as f:
            for r in rows:
                f.write(json.dumps(r, sort_keys=True) + "\n")

    dump("timeline.jsonl", [strip(e) for e in ev if e["event"] in TIMELINE])
    dump("search.jsonl", [strip(e) for e in ev if e["event"] in ("search", "typed_search")])
    homes = [e for e in ev if e["event"] == "home"]
    json.dump(strip(homes[-1]), open(os.path.join(out, "home.json"), "w"), indent=1, sort_keys=True)

    piles, typed = {}, {}
    for e in ev:
        if e["event"] == "search":
            piles.setdefault(e["preset"], []).append(e)
        elif e["event"] == "typed_search":
            typed.setdefault(e["query"], []).append(e)

    def pile(rows):
        warm = rows[1:]
        steps = ("queries", "pool", "lookup", "sql", "dot", "score", "decisions")
        return {"pool": rows[0]["pool"], "results": rows[0]["results"], "first_ms": round(rows[0]["ms"], 1),
                "first_steps_ms": {s: round(rows[0][f"{s}_ms"], 1) for s in steps},
                "warm_median_ms": round(st.median(e["ms"] for e in warm), 1),
                "warm_max_ms": round(max(e["ms"] for e in warm), 1),
                "warm_steps_median_ms": {s: round(st.median(e[f"{s}_ms"] for e in warm), 2) for s in steps}}

    def query(rows):
        return {"first_ms": round(rows[0]["ms"], 1), "warm_median_ms": round(st.median(e["ms"] for e in rows[1:]), 1),
                "matches": rows[0]["matches"], "weaker": rows[0]["weaker"], "byWords": rows[0]["byWords"],
                "compared": rows[0]["compared"]}

    model = [e for e in ev if e["event"] == "model"]
    prep = [e for e in model if e["state"].startswith("preparing")]
    ready = [e for e in model if e["state"] == "ready"]
    mem = [e for e in ev if e["event"] == "mem"]
    summary = {
        "device": {k: [e for e in ev if e["event"] == "session"][0][k] for k in ("machine", "osVersion", "cores")},
        "prepare": {"started_up_s": prep[0]["up"], "ready_up_s": ready[0]["up"] if ready else None,
                    "minutes": round((ready[0]["up"] - prep[0]["up"]) / 60, 1) if ready else None,
                    "step_up_s": [round(e["up"]) for e in prep]},
        "thermal": [[round(e["up"]), e["state"]] for e in ev if e["event"] == "thermal"],
        "memory_mb": {"peak": max(e["footprintMB"] for e in mem),
                      "peak_during_bench": max((e["footprintMB"] for e in mem
                                                if any(b["event"] == "search_bench" for b in ev)
                                                and e["up"] >= [b for b in ev if b["event"] == "search_bench"][0]["up"]),
                                               default=None)},
        "piles": {k: pile(v) for k, v in piles.items()},
        "typed": {k: query(v) for k, v in typed.items()},
        "text_pass": [strip(e) for e in ev if e["event"] == "text_pass"],
        "home": {k: homes[-1][k] for k in ("similarGroups", "similarMembers", "similarLargest", "dupGroups", "dupMembers",
                                            "dupLargest", "blurryCount", "blurryBytes", "screenshotsCount")},
        "last_up_s": ev[-1]["up"],
    }
    json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
