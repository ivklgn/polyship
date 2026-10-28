#!/usr/bin/env python3
"""Where the time and the suite runs of a ship.sh campaign go: a Pareto of causes, from the raw events.

    python3 lab/pareto.py <events.jsonl[.gz]>...      lab/race.sh MODE=ship campaigns, or lab/swarm.sh events.jsonl

Per worktree (one session), its ship.sh runs are cut at each ship-exit. Seconds by phase:
  before-queue  from the session start or the previous ship-exit to the run's first merge round (the tests before
                the queue, and the session's own turn between runs)
  wait          lock-wait .. lock-taken          lock  lock-taken .. merge-done
  agent         ship-conflict .. the next event  (the conflict agent's run)
and the same seconds, plus the suite runs, by how the ship.sh run ended (rc 0 landed, 1 red or stopped, 4 the fence,
5 lost commits, 137 killed). Waste = everything spent in runs that did not end in 0.
"""
import sys, json, gzip, collections
def lines(p):
    for l in (gzip.open(p, 'rt') if p.endswith('.gz') else open(p)):
        l = l.strip()
        if l: yield json.loads(l)
phase = collections.Counter(); by_rc = collections.Counter(); suites_rc = collections.Counter(); runs_rc = collections.Counter()
sessions = 0
for p in sys.argv[1:]:
    evs = list(lines(p))
    groups = collections.defaultdict(list)
    for e in evs:
        run = e.get('run', p)
        if e.get('ev') in ('start', 'session-start'):
            w = 'repo.' + (e.get('branch') or e.get('task')); groups[(run, w)].append(dict(e, ev='session-start'))
        elif 'wt' in e: groups[(run, e['wt'])].append(e)
        elif e.get('ev') == 'suite' and e.get('branch'): groups[(run, 'repo.' + e['branch'])].append(e)
    for key, es in groups.items():
        es.sort(key=lambda e: e['t'] or 0)
        if not any(e['ev'] == 'session-start' for e in es): continue
        sessions += 1
        t_prev = None; cur = collections.Counter(); cur_suites = 0; open_ev = None
        for e in es:
            k = e['ev']
            if k == 'session-start': t_prev = e['t']; continue
            if k == 'suite': cur_suites += 1; continue
            if k == 'ship-round' and t_prev is not None and e.get('round') == 1:
                cur['before-queue'] += e['t'] - t_prev; t_prev = None
            if open_ev:
                cur[open_ev[0]] += e['t'] - open_ev[1]; open_ev = None
            if k == 'lock-wait': open_ev = ('wait', e['t'])
            elif k == 'lock-taken': open_ev = ('lock', e['t'])
            elif k == 'ship-conflict': open_ev = ('agent', e['t'])
            elif k == 'ship-exit':
                rc = e['rc']; phase.update(cur); by_rc[rc] += sum(cur.values()); suites_rc[rc] += cur_suites; runs_rc[rc] += 1
                cur = collections.Counter(); cur_suites = 0; t_prev = e['t']
tot = sum(by_rc.values()) or 1; ts = sum(suites_rc.values()) or 1
print(f"sessions {sessions}; ship.sh runs {sum(runs_rc.values())}; seconds {tot:.0f}; suite runs {ts}")
print("by phase:   " + ", ".join(f"{k} {100 * v / tot:.0f}%" for k, v in phase.most_common()))
print("by ship.sh exit (runs, % seconds, % suite runs):")
for rc, v in sorted(by_rc.items(), key=lambda x: -x[1]):
    print(f"   rc {rc:>3}: {runs_rc[rc]:5d} runs  {100 * v / tot:5.1f}% s  {100 * suites_rc[rc] / ts:5.1f}% suites")
