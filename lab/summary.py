#!/usr/bin/env python3
"""Summarize lab/race.sh JSON lines: one row per mode.

    python3 lab/summary.py /tmp/race.*.jsonl
    python3 lab/summary.py measurements/2026-10-21/race/D.new.*.jsonl.gz   gzip is read as is
"""
import json, sys, collections, gzip

def pct(xs, p):
    if not xs: return "-"
    xs = sorted(xs); return f"{xs[min(len(xs) - 1, int(p * len(xs)))]:.1f}"

args = sys.argv[1:]
runs = collections.defaultdict(list)  # run id -> events
for path in args:
    for line in (gzip.open(path, "rt") if path.endswith(".gz") else open(path)):
        line = line.strip()
        if line:
            e = json.loads(line); runs[(e["mode"], e["run"])].append(e)

rows = collections.OrderedDict()
for (mode, run), evs in runs.items():
    head = next((e for e in evs if e["ev"] == "run"), None)
    if head is None or not any(e["ev"] == "run-end" for e in evs): continue  # an interrupted run counts for nothing
    key = (mode,)
    r = rows.setdefault(key, collections.Counter(runs=0)); r["runs"] += 1
    r.setdefault("tries", []); r.setdefault("secs", []); r.setdefault("wait", []); r.setdefault("wall", [])
    for e in evs:
        k = e["ev"]
        if k == "end":
            r["sessions"] += 1; r["out_" + e["outcome"]] += 1
            if e["outcome"] == "landed": r["tries"].append(e["tries"]); r["secs"].append(e["secs"])
        elif k == "violation": r["viol_" + e["kind"]] += 1; r["bad_runs_" + run] = 1
        elif k == "suite": r["suites"] += 1
        elif k == "overlap": r["overlap"] += 1
        elif k == "overlap-orphan":
            r["orphan"] += 1
            if e.get("relabeled"): r["overlap"] -= 1
        elif k == "restore": r["restore"] += 1
        elif k == "target-resynced": r["resync"] += 1
        elif k == "index-lock-removed": r["ilock"] += 1
        elif k == "lock-stale": r["stale"] += 1
        elif k == "recover": r["recover"] += 1
        elif k == "ship-conflict": r["conflicts"] += 1
        elif k == "attempt" and e.get("rebase"): r["conflicts_loop"] += 1
        elif k == "ship-exit": r[f"ship_rc{e['rc']}"] += 1
        elif k == "run-end": r["wall"].append(e["secs"])
        elif k == "dep-wait": r["depwait_" + e["where"]] += 1
        elif k == "dup-twice": r["duptwice"] += 1
        elif k == "start":
            if e.get("need", "none") != "none": r["consumers"] += 1
            if e.get("label") and e["label"] != e["branch"]: r["dups"] += 1
    waits = {}
    for e in evs:
        if e["ev"] == "lock-wait": waits[e["pid"]] = e["t"]
        elif e["ev"] == "lock-taken" and e["pid"] in waits: r["wait"].append(e["t"] - waits.pop(e["pid"]))

for key, r in rows.items():
    bad = sum(1 for k in r if k.startswith("bad_runs_"))
    landed = r["out_landed"]
    viol = {k[5:]: v for k, v in r.items() if k.startswith("viol_")}
    print(f"== {' '.join(str(k) for k in key)}: {r['runs']} runs, {r['sessions']} sessions")
    print(f"   outcomes   landed {landed}, refused {r['out_refused']}, owner {r['out_owner']}, gave-up {r['out_gave-up']}, dep-missing {r['out_dep-missing']}")
    if r["consumers"] or r["dups"]:
        print(f"   dependent sessions {r['consumers']} (dep waits: red before the queue {r['depwait_pre']}, red under the lock {r['depwait_lock']}); duplicate sessions {r['dups']} (a token on main twice: {r['duptwice']})")
    bound = f"; 0 bad runs in {r['runs']} → bad-run rate < {300 / r['runs']:.1f}% (95%, rule of three)" if bad == 0 else ""
    print(f"   violations {viol or 'none'} in {bad} run(s){bound}")
    print(f"   per landed branch: attempts p50 {pct(r['tries'], .5)} p95 {pct(r['tries'], .95)} max {max(r['tries'] or [0])}; "
          f"suite runs {r['suites'] / max(landed, 1):.2f}; time to land p50 {pct(r['secs'], .5)}s p95 {pct(r['secs'], .95)}s")
    print(f"   lock wait p50 {pct(r['wait'], .5)}s p95 {pct(r['wait'], .95)}s; stale takeovers {r['stale']}; suites overlapping {r['overlap']} (+{r['orphan']} orphans of a killed wt)")
    print(f"   lost-commit stops restored {r['restore']}; target checkouts re-synced {r['resync']}; stale index.lock removed {r['ilock']}")
    print(f"   conflicts {r['conflicts'] + r['conflicts_loop']}; open rebases finished before an attempt (conflict or kill) {r['recover']}; run wall p50 {pct(r['wall'], .5)}s")
    rc = {k[7:]: v for k, v in r.items() if k.startswith("ship_rc")}
    if rc: print(f"   ship.sh exit codes {dict(sorted(rc.items()))} (4 = the guard stopped: main moved during the agent run)")
