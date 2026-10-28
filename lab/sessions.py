#!/usr/bin/env python3
"""How many sessions the owner actually holds, and what that does to the owner: read Claude Code transcripts.

    python3 lab/sessions.py [~/.claude/projects] [--since 2026-09-01] [--json out.json]

A human session has >= 2 prompts typed by a person (turnOrigin human, or sdk from bb); one-prompt sessions are
headless runs (ship.sh's review/conflict agent, hotpot jobs) and are skipped. Per minute a session is
  running  -- it wrote an assistant or tool event in that minute,
  waiting  -- its last turn ended and the owner has not answered yet (capped at IDLE minutes: longer = the owner left).
Owner latency = time from the end of a turn (last event before the prompt) to the next typed prompt, binned by how many
OTHER sessions were open (running or waiting) at that moment. Gaps over IDLE are breaks, not latency, and are dropped.
Ships = Bash calls of ship.sh / merge.sh / `pnpm ship|merge` / `npm run ship` in human sessions.
Prints aggregates only; the transcripts stay where they are.
"""
import json, sys, glob, os, re, collections, datetime as dt
IDLE = 60  # minutes
args = [a for a in sys.argv[1:]]
root = os.path.expanduser(args[0] if args and not args[0].startswith('--') else '~/.claude/projects')
since = args[args.index('--since') + 1] if '--since' in args else '2000-01-01'
out = args[args.index('--json') + 1] if '--json' in args else None
SHIP = re.compile(r'(^|&&|;|\|\||\n)\s*(\S*/)?(ship|merge)\.sh\b|(^|&&|;|\n)\s*p?npm (run )?(ship|merge)\b')  # invoked as a command, not read or edited
COMMIT = re.compile(r'(^|&&|;|\n)\s*git (-C \S+ )?commit\b')
AUTO = ('Review the changes of this branch', 'A rebase onto ')

def ts(s): return dt.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()

sessions = []
for f in glob.glob(os.path.join(root, '*', '*.jsonl')):
    ev, prompts, ships, commits, errs = [], [], [], [], 0
    for line in open(f, errors='replace'):
        try: e = json.loads(line)
        except ValueError: continue
        t = e.get('timestamp'); typ = e.get('type')
        if not t or typ not in ('user', 'assistant'): continue
        if e.get('isSidechain'): continue
        x = ts(t); m = e.get('message') or {}; c = m.get('content')
        if typ == 'user' and isinstance(c, str) and not e.get('isMeta') and e.get('turnOrigin') in ('human', 'sdk') \
                and not c.startswith(AUTO) and not c.startswith('<'):
            prompts.append(x); ev.append((x, 'p'))
            continue
        ev.append((x, 'a'))
        if typ == 'assistant':
            if e.get('isApiErrorMessage') or (isinstance(c, list) and any('rate_limit' in str(b.get('text', ''))[:300] or 'overloaded' in str(b.get('text', ''))[:300].lower() for b in c if isinstance(b, dict) and b.get('type') == 'text') and e.get('isApiErrorMessage') is not False):
                errs += 1
            for b in c if isinstance(c, list) else []:
                if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') == 'Bash' and SHIP.search(str((b.get('input') or {}).get('command', ''))):
                    ships.append(x)
                if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') == 'Bash' and COMMIT.search(str((b.get('input') or {}).get('command', ''))):
                    commits.append(x)
                if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') == 'Skill' and 'commit' in str((b.get('input') or {}).get('skill', '')):
                    commits.append(x)
    if len(prompts) < 2 or min(prompts) < ts(since + 'T00:00:00+00:00'): continue
    ev.sort()
    sessions.append(dict(file=f, ev=ev, prompts=prompts, ships=sorted(ships), commits=sorted(commits), errs=errs,
                         project=os.path.basename(os.path.dirname(f))))

# per-minute state of every session
def minute(x): return int(x // 60)
running = collections.defaultdict(set); waiting = collections.defaultdict(set)
lat = []  # (other_open, latency_min)
for i, s in enumerate(sessions):
    ev = s['ev']
    for x, k in ev:
        if k == 'a': running[minute(x)].add(i)
    for (x0, k0), (x1, k1) in zip(ev, ev[1:]):
        if k1 == 'p' and k0 == 'a':
            gap = (x1 - x0) / 60
            for mm in range(minute(x0) + 1, minute(min(x1, x0 + IDLE * 60)) + 1): waiting[mm].add(i)
            if gap <= IDLE: lat.append((x0, gap, i))
openm = {m: running[m] | waiting[m] for m in set(running) | set(waiting)}
for j, (x0, gap, i) in enumerate(lat):
    lat[j] = (len(openm.get(minute(x0), set()) - {i}), gap)

def q(xs, p):
    xs = sorted(xs); return round(xs[min(len(xs) - 1, int(p * len(xs)))], 1) if xs else None
hist_open = collections.Counter(len(v) for v in openm.values())
hist_run = collections.Counter(len(v) for v in running.values())
day_peak = collections.defaultdict(int)
for m, v in openm.items(): d = dt.datetime.fromtimestamp(m * 60).date().isoformat(); day_peak[d] = max(day_peak[d], len(v))
by = collections.defaultdict(list)
for o, g in lat: by[min(o, 8)].append(g)
inter = [(b - a) / 60 for s in sessions for a, b in zip(s['ships'], s['ships'][1:]) if (b - a) / 60 < 8 * 60]
cint = [(b - a) / 60 for s in sessions for a, b in zip(s['commits'], s['commits'][1:]) if (b - a) / 60 < 8 * 60]
first_commit = [(s['commits'][0] - s['prompts'][0]) / 60 for s in sessions if s['commits']]
first_ship = [(s['ships'][0] - s['prompts'][0]) / 60 for s in sessions if s['ships']]
res = dict(
    human_sessions=len(sessions), with_ship=sum(1 for s in sessions if s['ships']), ships=sum(len(s['ships']) for s in sessions),
    minutes_open_by_concurrency=dict(sorted(hist_open.items())), minutes_running_by_concurrency=dict(sorted(hist_run.items())),
    daily_peak_open=dict(sorted(day_peak.items())),
    owner_latency_min_by_other_open={('8+' if k == 8 else k): dict(n=len(v), p50=q(v, .5), p75=q(v, .75), p90=q(v, .9)) for k, v in sorted(by.items())},
    minutes_between_ships_in_a_session=dict(n=len(inter), p25=q(inter, .25), p50=q(inter, .5), p75=q(inter, .75)),
    minutes_from_first_prompt_to_first_ship=dict(n=len(first_ship), p50=q(first_ship, .5), p75=q(first_ship, .75)),
    sessions_with_commit=sum(1 for s in sessions if s['commits']), commits=sum(len(s['commits']) for s in sessions),
    minutes_between_commits_in_a_session=dict(n=len(cint), p25=q(cint, .25), p50=q(cint, .5), p75=q(cint, .75), p90=q(cint, .9)),
    minutes_from_first_prompt_to_first_commit=dict(n=len(first_commit), p25=q(first_commit, .25), p50=q(first_commit, .5), p75=q(first_commit, .75)),
    api_error_messages=sum(s['errs'] for s in sessions),
)
print(json.dumps(res, indent=1, ensure_ascii=False))
if out: json.dump(res, open(out, 'w'), indent=1, ensure_ascii=False)
