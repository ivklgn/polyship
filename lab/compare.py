#!/usr/bin/env python3
"""Before/after of two lab/race.sh campaigns on the same seeds, with 95 % bootstrap intervals over runs.

    python3 lab/compare.py <before.jsonl[.gz]> <after.jsonl[.gz]> [--paired]
--paired: only the branches that landed on both sides in the run of the same seed (mode-seed-branch), so a side that
loses its slow branches does not look faster (survivorship): time to land and the summed lock wait per branch.
Per campaign: violations, bad runs, landed, exit 4 per landed branch, suite runs per landed branch, p95 lock wait,
p95 time to land. The interval resamples whole runs (2 000 times): sessions of one run are not independent.
"""
import sys, json, gzip, random, collections
def events(paths):
    for p in paths.split(','):
        for l in (gzip.open(p, 'rt') if p.endswith('.gz') else open(p)):
            yield l
def load(p):
    runs = collections.defaultdict(list)
    for l in events(p):
        l = l.strip()
        if l: e = json.loads(l); runs[e['run']].append(e)
    out = []
    for r, es in runs.items():
        if not any(e['ev'] == 'run-end' for e in es): continue
        w = {}; waits = []
        for e in es:
            if e['ev'] == 'lock-wait': w[e['pid']] = e['t']
            elif e['ev'] == 'lock-taken' and e['pid'] in w: waits.append(e['t'] - w.pop(e['pid']))
        out.append(dict(viol=sum(e['ev'] == 'violation' for e in es),
                        landed=sum(e['ev'] == 'end' and e['outcome'] == 'landed' for e in es),
                        e4=sum(e['ev'] == 'ship-exit' and e['rc'] == 4 for e in es),
                        suites=sum(e['ev'] == 'suite' for e in es), waits=waits,
                        land=[e['secs'] for e in es if e['ev'] == 'end' and e['outcome'] == 'landed']))
    return out
def q(xs, p): xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float('nan')
M = dict(exit4_per_landed=lambda rs: sum(r['e4'] for r in rs) / max(sum(r['landed'] for r in rs), 1),
         suites_per_landed=lambda rs: sum(r['suites'] for r in rs) / max(sum(r['landed'] for r in rs), 1),
         wait_p95=lambda rs: q([x for r in rs for x in r['waits']], .95),
         land_p95=lambda rs: q([x for r in rs for x in r['land']], .95))
def ci(rs, f, n=2000, seed=1):
    rnd = random.Random(seed); v = sorted(f([rnd.choice(rs) for _ in rs]) for _ in range(n)); return v[int(.025 * n)], v[int(.975 * n)]
b, a = load(sys.argv[1]), load(sys.argv[2])
for name, rs in (('before', b), ('after', a)):
    print(f"{name:6s}: runs {len(rs)}, violations {sum(r['viol'] for r in rs)} in {sum(r['viol'] > 0 for r in rs)} runs, landed {sum(r['landed'] for r in rs)}")
for k, f in M.items():
    lo_b, hi_b = ci(b, f); lo_a, hi_a = ci(a, f)
    print(f"{k:18s} before {f(b):7.3f} [{lo_b:.3f}, {hi_b:.3f}]   after {f(a):7.3f} [{lo_a:.3f}, {hi_a:.3f}]   change {100 * (f(a) - f(b)) / f(b) if f(b) else float('nan'):+.0f} %")

def paired(p):  # (seed, branch) -> (seconds to land, summed lock wait)
    out = {}; runs = collections.defaultdict(list)
    for l in events(p):
        l = l.strip()
        if l: e = json.loads(l); runs[e['run']].append(e)
    for r, es in runs.items():
        if not any(e['ev'] == 'run-end' for e in es): continue
        seed = r.rsplit('-', 1)[0]; w = {}; wait = collections.Counter()
        for e in es:
            if e['ev'] == 'lock-wait': w[e['pid']] = (e['t'], e['wt'])
            elif e['ev'] == 'lock-taken' and e['pid'] in w: t, wt = w.pop(e['pid']); wait[wt.split('.')[-1]] += e['t'] - t
        for e in es:
            if e['ev'] == 'end' and e['outcome'] == 'landed': out[(seed, e['branch'])] = (e['secs'], wait[e['branch']])
    return out
if '--paired' in sys.argv:
    pb, pa = paired(sys.argv[1]), paired(sys.argv[2]); keys = sorted(set(pb) & set(pa))
    print(f"paired: {len(keys)} branches landed on both sides (before {len(pb)}, after {len(pa)})")
    for i, name in ((0, 'time to land'), (1, 'lock wait per branch')):
        b_ = [pb[k][i] for k in keys]; a_ = [pa[k][i] for k in keys]; d = sorted(a_[j] - b_[j] for j in range(len(keys)))
        rnd = random.Random(1); boot = sorted(q([rnd.choice(a_) for _ in a_], .95) - q([rnd.choice(b_) for _ in b_], .95) for _ in range(1000))
        print(f"  {name:22s} p50 {q(b_, .5):6.2f} -> {q(a_, .5):6.2f} s; p95 {q(b_, .95):6.2f} -> {q(a_, .95):6.2f} s "
              f"(p95 change {q(a_, .95) - q(b_, .95):+.2f} s [{boot[25]:+.2f}, {boot[975]:+.2f}]); median paired difference {d[len(d) // 2]:+.2f} s")
