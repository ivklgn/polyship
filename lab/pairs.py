#!/usr/bin/env python3
"""Which commits of a real history depend on an earlier one, textually or only semantically?

    python3 lab/pairs.py <repo> [--max-distance 6] [--suite "<cmd>" --clone <prepared clone>] [--out pairs.jsonl]

For every pair A -> B of first-parent commits at distance <= max-distance:
  X = B's parent with only A taken out (A reverted onto B^ by merge-tree). If that revert conflicts, later commits
      built on A and "B without A" is not defined: form "chain".
  B on X conflicts: form "textual" (B could not have been written in parallel with A without a conflict).
  B on X applies cleanly: form "clean". With --suite, the suite runs on B and on B-without-A in the clone
      (a prepared clone of the repo: dependencies installed; reinstalled when the lockfile changes); red on
      B-without-A and green on B = "semantic": no conflict, yet B needs A. A red result is run twice.
merge-tree writes the trees it builds as loose objects into <repo>; they are unreachable and go with git gc.
"""
import subprocess, json, sys, os, re, collections, time
args = sys.argv[1:]; R = os.path.abspath(args[0])
opt = lambda k, d=None: args[args.index(k) + 1] if k in args else d
D = int(opt('--max-distance', 6)); SUITE = opt('--suite'); CLONE = opt('--clone'); OUT = opt('--out', '/tmp/pairs.jsonl')
def g(*a, cwd=R): return subprocess.run(['git', *a], capture_output=True, text=True, cwd=cwd)
cs = g('rev-list', '--reverse', '--first-parent', '--no-merges', 'main').stdout.split()
rows = []
for i, a in enumerate(cs[1:], 1):
    for b in cs[i + 1:i + 1 + D]:
        x = g('merge-tree', '--write-tree', f'--merge-base={a}', f'{b}^', f'{a}^')
        if x.returncode != 0: rows.append(dict(a=a, b=b, d=cs.index(b) - i, form='chain')); continue
        y = g('merge-tree', '--write-tree', f'--merge-base={b}^', x.stdout.split()[0], b)
        rows.append(dict(a=a, b=b, d=cs.index(b) - i, form='textual' if y.returncode == 1 else 'clean', tree=y.stdout.split()[0] if y.returncode == 0 else None))
lock = None
def run(tree_or_commit):
    global lock
    c = CLONE
    g('read-tree', '-u', '--reset', tree_or_commit, cwd=c)
    lf = g('rev-parse', f'{tree_or_commit}:pnpm-lock.yaml', cwd=c).stdout.strip()
    if lf and lf != lock:
        subprocess.run('pnpm install --frozen-lockfile --prefer-offline', shell=True, cwd=c, capture_output=True); lock = lf
    t0 = time.time(); r = subprocess.run(SUITE, shell=True, cwd=c, capture_output=True, text=True)
    return r.returncode == 0, round(time.time() - t0, 1), (r.stdout + r.stderr)[-600:]
if SUITE:
    cache = {}
    for r in rows:
        if r['form'] != 'clean': continue
        if r['b'] not in cache: cache[r['b']] = run(r['b'])
        r['suite_b'] = cache[r['b']][0]
        if not r['suite_b']: continue
        ok, secs, tail = run(r['tree'])
        if not ok: ok, secs, tail = run(r['tree'])  # a red result twice before it counts
        r['suite_without_a'] = ok; r['form'] = 'clean' if ok else 'semantic'
        if not ok: r['tail'] = tail
        print(r['a'][:8], r['b'][:8], r['form'], file=sys.stderr)
with open(OUT, 'w') as f:
    for r in rows: f.write(json.dumps(r) + '\n')
c = collections.Counter(r['form'] for r in rows)
print(f"commits {len(cs)}, pairs {len(rows)}: {dict(c)}" + (f"; clean pairs whose B was red on its own: {sum(1 for r in rows if r.get('suite_b') is False)}" if SUITE else ''))
