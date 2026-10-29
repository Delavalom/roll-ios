"""Regenerates this folder's extracts from Roll's raw QA log (identifier-free events only).

    python3 extract.py ~/egcm-evidence-raw/2026-10-29/roll-proof/qa/metrics.jsonl .

Session 1 = the proof launch (09:10:27 AST, t >= S1); session 2 = the search benchmark relaunch (11:19:13, t >= S2).
`session1-index-batches.jsonl` columns: [up s, processed, items/s, thermal 0-3, previews in batch].
"""
import json
import os
import statistics as st
import sys

S1, S2 = 1793279427, 1793287100


def main(raw: str, out: str) -> None:
    ev = [json.loads(line) for line in open(raw)]
    s1 = [e for e in ev if S1 <= e.get("t", 0) < S2]
    s2 = [e for e in ev if e.get("t", 0) >= S2]

    def dump(name, rows):
        with open(os.path.join(out, name), "w") as f:
            for r in rows:
                f.write(json.dumps(r, sort_keys=True) + "\n")

    dump("session1-model-and-runs.jsonl",
         [e for e in s1 if e["event"] in ("session", "model", "library_totals", "index_run", "search_bench")])
    dump("session1-index-batches.jsonl",
         [[round(e["up"]), e["processed"], round(e["itemsPerSecond"], 1), e["thermal"], e["previews"]]
          for e in s1 if e["event"] == "index_batch"])
    dump("session1-thermal.jsonl", [{k: e[k] for k in ("up", "state", "reason")} for e in s1 if e["event"] == "thermal"])
    dump("session2-search.jsonl", [e for e in s2 if e["event"] in ("session", "model", "search_bench", "search")])
    home = [e for e in s1 if e["event"] == "home"][-1]
    store = [e for e in s1 if e["event"] == "store_stats"][-1]
    json.dump({"home": home, "store_stats": store}, open(os.path.join(out, "session1-final-home-and-store.json"), "w"),
              indent=1, sort_keys=True)

    model = [e for e in s1 if e["event"] == "model"]
    prep = [e for e in model if e["state"].startswith("preparing")]
    ready = [e for e in model if e["state"] == "ready"][0]
    fin = [e for e in s1 if e["event"] == "index_run" and e.get("state") == "finished" and e.get("thumbs", 0) > 20000][0]
    start = [e for e in s1 if e["event"] == "index_run" and e.get("state") == "started" and e["up"] >= ready["up"] - 2][0]
    th = [e for e in s1 if e["event"] == "thermal"]
    pauses = [e for e in s1 if e["event"] == "index_run" and e.get("state") == "thermalPause"
              and start["up"] <= e["up"] <= fin["up"]]

    def share(a, b):
        dur, t = {}, a
        before = [e for e in th if e["up"] <= a]
        cur = before[-1]["state"] if before else "nominal"
        for e in th:
            if e["up"] <= a or e["up"] > b:
                continue
            dur[cur] = dur.get(cur, 0) + e["up"] - t
            t, cur = e["up"], e["state"]
        dur[cur] = dur.get(cur, 0) + b - t
        return {k: round(v / (b - a), 3) for k, v in dur.items()}

    mem = [e for e in s1 if e["event"] == "mem"]
    by = {}
    for e in s2:
        if e["event"] == "search":
            by.setdefault(e["preset"], []).append(e["ms"])
    summary = {
        "device": {k: [e for e in s1 if e["event"] == "session"][0][k]
                   for k in ("machine", "osVersion", "physicalMemory", "cores", "photosAccess")},
        "library_totals": {k: v for k, v in [e for e in s1 if e["event"] == "library_totals"][0].items()
                           if k not in ("t", "up", "event")},
        "prepare": {"started_up_s": prep[0]["up"], "ready_up_s": ready["up"],
                    "minutes": round((ready["up"] - prep[0]["up"]) / 60, 1), "step_up_s": [round(e["up"]) for e in prep]},
        "index_full": {"started_up_s": round(start["up"]), "finished_up_s": round(fin["up"]),
                       "seconds": round(fin["seconds"], 1), "minutes": round(fin["seconds"] / 60, 1),
                       "thumbs": fin["thumbs"], "full": fin["full"], "previews": fin["previews"],
                       "inCloud": fin["inCloud"], "failed": fin["failed"],
                       "overall_items_per_s": round(fin["thumbs"] / fin["seconds"], 2), "thermal_pauses": len(pauses),
                       "batch_items_per_s_median": round(st.median(
                           e["itemsPerSecond"] for e in s1 if e["event"] == "index_batch" and e["up"] > start["up"]), 1),
                       "thermal_share": share(start["up"], fin["up"])},
        "memory_mb": {"peak_while_preparing": max(e["footprintMB"] for e in mem if e["up"] < ready["up"]),
                      "peak_at_handover": max(e["footprintMB"] for e in mem if start["up"] <= e["up"] < start["up"] + 60),
                      "peak_while_indexing": max(e["footprintMB"] for e in mem if start["up"] + 60 <= e["up"] <= fin["up"]),
                      "limit_mb": mem[-1].get("limitMB")},
        "search_ms": {p: {"attempts": [round(x, 1) for x in v], "median_warm": round(st.median(v[1:]), 1)}
                      for p, v in by.items()},
        "store_embedded": store["data"]["embedded"], "store_signalsDone": store["data"]["signalsDone"],
    }
    json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
