#!/usr/bin/env python3
"""The queue model of the merge lock, checked against the stand, then used to size real projects.

    python3 lab/queue.py check <race.jsonl[.gz]>...          does the lock behave as one ideal server?
    python3 lab/queue.py predict --T 15 --W 1800 [--N 2,4,...] [--slow 1:1,2:1.7,4:3.5] [--p-conflict .15] [--A 100]
        [--o 2] [--open <window s>] [--reps 1] [--Adist exp|uniform] [--order random|fifo]
        [--exit4 stop|continue] [--pre 1|0] [--batch k]   what-if: ship.sh goes on after another session's merge; no tests
        before the queue; up to k waiting branches merged under one suite run (a red batch is not modeled)

check, per run of lab/race.sh: lock requests (lock-wait), service S = lock-taken..merge-done of the same pid.
  idle   = seconds the lock was free while a request waited (a work-conserving lock has ~0: flock wakes a waiter)
  lindley = mean wait of a FIFO single server fed the same arrivals and services, vs the measured mean wait
  pk     = the Pollaczek-Khinchine mean wait lambda*E[S^2]/(2(1-rho)) from the run's own lambda and S (steady state only)
  Runs with a SIGKILL are skipped (a killed holder leaves no merge-done).
predict: N sessions in a closed loop (a task takes Exp(W) seconds of agent work, then ship.sh): the suite before
  the queue (outside the lock), then the lock: the suite again + overhead; with probability p-conflict the rebase
  stops and an agent works A seconds (Exp); if another merge lands meanwhile, ship.sh exits 4 and the session ships
  again. Every suite run is slowed by the number of suites running at once (--slow k:factor, measured by
  lab/suite-time.sh; linear between points). Prints per N: lock utilization, wait p50/p95, exit-4 share, time from
  ship to landed p95.
"""
import sys, json, gzip, collections, random, heapq, math

def read(paths):
    runs = collections.defaultdict(list)
    for p in paths:
        for line in (gzip.open(p, 'rt') if p.endswith('.gz') else open(p)):
            line = line.strip()
            if line: e = json.loads(line); runs[e.get('run')].append(e)
    return runs

def check(paths):
    tot = collections.Counter(); rows = []
    for run, evs in read(paths).items():
        if any(e['ev'] == 'attempt' and e.get('rc') == 137 for e in evs): tot['skipped_killed'] += 1; continue
        w, tk, done = {}, {}, {}
        for e in evs:
            if e['ev'] == 'lock-wait': w[e['pid']] = e['t']
            elif e['ev'] == 'lock-taken': tk[e['pid']] = e['t']
            elif e['ev'] == 'merge-done' and e['pid'] in tk: done[e['pid']] = e['t']
        req = sorted((w[p], tk[p] - w[p], done[p] - tk[p], tk[p], done[p]) for p in done if p in w)
        if len(req) < 3: continue
        # idle with waiters: walk the timeline
        held = sorted((t0, t1) for *_, t0, t1 in req)
        idle = 0.0
        for a, wait, s, t0, t1 in req:
            if wait <= 0.05: continue
            # parts of [a, t0] not covered by any holder
            cur = a
            for h0, h1 in held:
                if h1 <= cur or h0 >= t0: continue
                if h0 > cur: idle += h0 - cur
                cur = max(cur, h1)
                if cur >= t0: break
            if cur < t0: idle += t0 - cur
        free = 0.0; fifo = []
        for a, wait, s, *_ in req:
            start = max(a, free); fifo.append(start - a); free = start + s
        span = req[-1][0] - req[0][0] or 1
        lam = (len(req) - 1) / span; S = [r[2] for r in req]; ES = sum(S) / len(S); ES2 = sum(x * x for x in S) / len(S)
        rho = lam * ES; pk = lam * ES2 / (2 * (1 - rho)) if rho < 1 else float('inf')
        rows.append(dict(run=run, n=len(req), rho=rho, ES=ES, wait=sum(r[1] for r in req) / len(req), lindley=sum(fifo) / len(fifo), pk=pk, idle=idle))
    if not rows: print('no runs'); return
    def m(k): return sum(r[k] for r in rows) / len(rows)
    print(f"runs {len(rows)} (skipped with a SIGKILL: {tot['skipped_killed']}); requests per run {m('n'):.0f}; rho {m('rho'):.2f}; E[S] {m('ES'):.2f}s")
    print(f"mean wait: measured {m('wait'):.2f}s, FIFO replay (Lindley) {m('lindley'):.2f}s, Pollaczek-Khinchine {m('pk'):.2f}s")
    print(f"lock idle while a request waited: {m('idle'):.2f}s per run ({100 * m('idle') / max(m('wait') * m('n'), 1e-9):.1f}% of all waiting)")
    return rows

def predict(argv):
    a = dict(T=15.0, W=1800.0, N='1,2,4,6,8,10,12,16,20', slow='1:1', A=100.0, o=2.0, hours=200, seed=1, open=0, reps=1, Adist='exp', order='random', exit4='stop', pre='1', batch='1')
    a['p-conflict'] = 0.15
    for i in range(0, len(argv), 2): a[argv[i].lstrip('-')] = argv[i + 1]
    T, W, A, o, pc, OPEN = float(a['T']), float(a['W']), float(a['A']), float(a['o']), float(a['p-conflict']), float(a['open'])
    slow = sorted((float(k), float(v)) for k, v in (x.split(':') for x in str(a['slow']).split(',')))
    def factor(k):  # how much slower one suite runs when k run at once; linear between the measured points, flat past the last
        if k <= slow[0][0]: return slow[0][1]
        for (k0, f0), (k1, f1) in zip(slow, slow[1:]):
            if k <= k1: return f0 + (f1 - f0) * (k - k0) / (k1 - k0)
        if len(slow) == 1: return slow[0][1]
        (k0, f0), (k1, f1) = slow[-2:]; return f1 + (f1 - f0) / (k1 - k0) * (k - k1)
    print(f"T={T}s W={W}s A={A}s ({a['Adist']}) overhead={o}s p-conflict={pc} slow={a['slow']}" + (f" open window={OPEN}s" if OPEN else ''))
    print("   N  lock-util  wait-p50  wait-p95  exit4-per-landed  sessions-with-exit4  ship-to-landed-p50  -p95  suites-at-once-max")
    for N in [int(x) for x in str(a['N']).split(',')]:
        W_, L_, E4, LD, BUSY, SPAN, KMAX, SE4 = [], [], 0, 0, 0.0, 0.0, 0, 0
        for rep in range(int(a['reps'])):
            r = Sim(N, T, W, A, o, pc, OPEN, factor, a['Adist'], random.Random(int(a['seed']) + rep), float(a['hours']) * 3600, a['order'], a['exit4'], a['pre'] != '0', int(a['batch']))
            W_ += r.waits; L_ += r.lands; E4 += r.exit4; SE4 += len(r.e4s); LD += len(r.lands); BUSY += r.busy; SPAN += r.now; KMAX = max(KMAX, r.kmax)
        q = lambda xs, p: sorted(xs)[min(len(xs) - 1, int(p * len(xs)))] if xs else float('nan')
        print(f"{N:4d}  {BUSY / max(SPAN, 1e-9):9.2f}  {q(W_, .5):7.1f}s  {q(W_, .95):7.1f}s  {100 * E4 / max(LD, 1):15.0f}%  {100 * SE4 / max(LD, 1):18.0f}%  {q(L_, .5):17.1f}s  {q(L_, .95):5.0f}s  {KMAX:18d}")

class Sim:
    """N sessions; suites share the CPU (processor sharing with the measured slow-down); one lock, random wake order."""
    def __init__(s, N, T, W, A, o, pc, OPEN, factor, Adist, rnd, horizon, order='random', exit4='stop', pre=True, batch=1):
        s.order = order; s.batch = batch; s.e4mode = exit4; s.pre = pre; s.T, s.W, s.A, s.o, s.pc, s.OPEN, s.factor, s.Adist, s.rnd = T, W, A, o, pc, OPEN, factor, Adist, rnd
        s.now = 0.0; s.ev = []; s.seq = 0; s.suites = {}; s.holder = None; s.queue = []; s.merges = 0
        s.waits, s.lands, s.exit4, s.busy, s.kmax = [], [], 0, 0.0, 0; s.st = {}; s.e4s = set(); s.task = collections.Counter()
        for i in range(N): s.push(rnd.uniform(0, OPEN) if OPEN else rnd.expovariate(1 / W), 'ship', i)
        while True:
            nxt = s.next_suite()
            if s.ev and (nxt is None or s.ev[0][0] <= nxt[0]):
                when, _, kind, i = heapq.heappop(s.ev)
                if when > horizon: break
                s.advance(when); getattr(s, kind)(i)
            elif nxt:
                s.advance(nxt[0]); (i, phase) = nxt[1]; del s.suites[nxt[1]]; (s.pre_done if phase == 'pre' else s.lock_done)(i)
            else: break
    def push(s, when, kind, i): s.seq += 1; heapq.heappush(s.ev, (when, s.seq, kind, i))
    def advance(s, t):
        if s.suites:
            f = s.factor(len(s.suites))
            for k in s.suites: s.suites[k] -= (t - s.now) / f
        s.now = t
    def next_suite(s):
        if not s.suites: return None
        k = min(s.suites, key=s.suites.get); return s.now + max(s.suites[k], 0) * s.factor(len(s.suites)), k
    def run_suite(s, i, phase, work): s.suites[(i, phase)] = work; s.kmax = max(s.kmax, len(s.suites))
    def ship(s, i):  # ship.sh: the suite before the queue
        s.st.setdefault(i, dict(t_ship=s.now))
        if s.pre: s.run_suite(i, 'pre', s.T)
        else: s.request(i)
    def pre_done(s, i): s.request(i)
    def request(s, i):
        s.st[i]['t_req'] = s.now
        if s.holder is None: s.take(i)
        else: s.queue.append(i)
    def take(s, i):
        # with --batch k the holder also takes up to k-1 more waiters and runs one suite for all of them (always green
        # here: a red batch and its bisect are not modeled)
        group = [i] + [s.queue.pop(0 if s.order == 'fifo' else s.rnd.randrange(len(s.queue))) for _ in range(min(s.batch - 1, len(s.queue)))]
        keep = []
        for j in group:
            st = s.st[j]; st['t_lock'] = s.now; s.waits.append(s.now - st['t_req'])
            if not st.get('resolved') and s.rnd.random() < s.pc:  # the rebase stops on a conflict: out of the batch, agent works
                st['resolved'] = True; st['m0'] = s.merges
                s.push(s.now + (s.rnd.uniform(0, 2 * s.A) if s.Adist == 'uniform' else s.rnd.expovariate(1 / s.A)), 'agent_done', j)
            else: keep.append(j)
        if not keep: s.holder = None; s.release(); return
        s.holder = tuple(keep); s.groups = getattr(s, 'groups', {}); s.groups[keep[0]] = keep; s.run_suite(keep[0], 'lock', s.T + s.o)
    def release(s):
        s.holder = None
        if s.queue: s.take(s.queue.pop(0 if s.order == 'fifo' else s.rnd.randrange(len(s.queue))))  # flock promises no order; --order fifo
    def lock_done(s, i):
        group = s.groups.pop(i)
        s.busy += s.now - s.st[i]['t_lock']; s.merges += 1
        for j in group:
            st = s.st.pop(j); s.task[j] += 1; s.lands.append(s.now - st['t_ship'])
            if not s.OPEN: s.push(s.now + s.rnd.expovariate(1 / s.W), 'ship', j)
        s.release()
    def agent_done(s, i):
        if s.merges > s.st[i]['m0']:  # exit 4: the session runs ship.sh again (tests first); the new rebase may conflict again
            s.st[i]['resolved'] = False
            if s.e4mode == 'continue': s.request(i)  # ship.sh lets another session's merge through: next round, rebase again
            else: s.exit4 += 1; s.e4s.add((i, s.task[i])); s.ship(i)
        else: s.request(i)  # ship.sh's next round: merge.sh again

if __name__ == '__main__':
    if sys.argv[1:2] == ['check']: check(sys.argv[2:])
    elif sys.argv[1:2] == ['predict']: predict(sys.argv[2:])
    else: print(__doc__)
