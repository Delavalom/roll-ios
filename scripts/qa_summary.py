#!/usr/bin/env python3
"""Summarizes a device-QA metrics.jsonl (identifier-free; see docs/qa/device-2026-10-23.md).

    python3 scripts/qa_summary.py artifacts/qa/device/metrics.jsonl [--since UP] [--until UP]

Each launch of the app restarts `up` (seconds since the recorder started); sessions are split on the `session` event.
"""
import json
import statistics
import sys


def load(path):
    sessions, current = [], None
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        if d["event"] == "session":
            current = {"session": d, "events": []}
            sessions.append(current)
        elif current is not None:
            current["events"].append(d)
    return sessions


def mb(b):
    return f"{b / 1_048_576:,.0f} MB"


def gb(b):
    return f"{b / 1e9:,.2f} GB"


def summarize(s, index):
    ses, ev = s["session"], s["events"]
    print(f"\n=== session {index}: {ses['machine']} iOS {ses['osVersion']} mode={ses['mode']} "
          f"RAM={gb(ses['physicalMemory'])} cores={ses['cores']}")
    by = {}
    for e in ev:
        by.setdefault(e["event"], []).append(e)
    mem = by.get("mem", [])
    if mem:
        fp = [m["footprintMB"] for m in mem]
        print(f"memory: {len(mem)} samples over {mem[-1]['up']:.0f} s; footprint median {statistics.median(fp):.0f} MB, "
              f"p95 {sorted(fp)[int(0.95 * (len(fp) - 1))]:.0f} MB, peak {max(m['peakMB'] for m in mem):.0f} MB; "
              f"limit (footprint+available) ~{statistics.median(m['limitMB'] for m in mem):.0f} MB")
        phases = {}
        for m in mem:
            phases.setdefault(m["phase"], []).append(m["footprintMB"])
        for p, v in phases.items():
            print(f"  phase {p:12s} n={len(v):4d} median {statistics.median(v):6.0f} MB max {max(v):6.0f} MB")
    for name in ("thermal", "battery", "model"):
        rows = by.get(name, [])
        changes = [r for r in rows if r.get("reason") != "periodic"]
        if name == "battery":
            changes = rows[:1] + [r for r in rows[1:] if r.get("reason") == "change"] + rows[-1:]
        print(f"{name}: " + "; ".join(
            f"{r['up']:.0f}s {r.get('state')}{' ' + str(round(r['level'] * 100)) + '%' if 'level' in r else ''}"
            for r in changes))
    if "library_totals" in by:
        t = dict(by["library_totals"][-1])
        for k in ("event", "t", "up"):
            t.pop(k, None)
        print("library_totals:", json.dumps(t, sort_keys=True))
    for r in by.get("index_run", []):
        keep = {k: r[k] for k in r if k not in ("event", "t")}
        print("index_run:", json.dumps(keep, sort_keys=True))
    batches = by.get("index_batch", [])
    if batches:
        rates = [b["itemsPerSecond"] for b in batches]
        cloud = sum(b["inCloud"] for b in batches)
        failed = sum(b["failed"] for b in batches)
        thumbs = sum(b["thumbs"] for b in batches)
        print(f"index_batch: {len(batches)} batches, items/s median {statistics.median(rates):.1f} "
              f"(min {min(rates):.1f}, max {max(rates):.1f}); thumbs {thumbs}, inCloud {cloud} "
              f"({cloud / max(thumbs, 1):.1%}), failed {failed} ({failed / max(thumbs, 1):.1%})")
        slow = sorted(batches, key=lambda b: b["itemsPerSecond"])[:3]
        print("  slowest:", [(round(b["itemsPerSecond"], 1), b["processed"], b["thermal"]) for b in slow])
        by_thermal = {}
        for b in batches:
            by_thermal.setdefault(b["thermal"], []).append(b["itemsPerSecond"])
        print("  items/s by thermal state:", {k: round(statistics.median(v), 1) for k, v in sorted(by_thermal.items())})
    if "store_stats" in by:
        print("store_stats(last):", json.dumps(by["store_stats"][-1]["data"], sort_keys=True))
    if "home" in by:
        h = by["home"][-1]
        print(f"home(last of {len(by['home'])}):", json.dumps({k: h[k] for k in sorted(h) if k not in ('event', 't')}))
    if "monitor" in by:
        m = by["monitor"][-1]
        print("monitor(last):", json.dumps({k: m[k] for k in sorted(m) if k not in ('event', 't')}))
    for name in ("album_inventory", "qa_gate", "qa_fake_space", "qa_exhaust_quota", "squish_prepared", "squish_failed",
                 "squish_cancelled", "squish_before_delete", "squish_commit", "squish_copy_after_delete", "dv_experiment",
                 "dv_experiment_skip", "dv_experiment_done", "thumb_probe", "signal_timing", "sync_read",
                 "squish_catalog", "locality_verify", "locality_scan", "types_resolved", "qa_config_error", "upgrade_pass"):
        for r in by.get(name, []):
            keep = {k: r[k] for k in r if k not in ("event", "t")}
            print(f"{name}:", json.dumps(keep, sort_keys=True)[:1500])


def main():
    sessions = load(sys.argv[1])
    for i, s in enumerate(sessions):
        summarize(s, i)


if __name__ == "__main__":
    main()
