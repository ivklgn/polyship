#!/usr/bin/env bash
# The oracle of lab/swarm.sh, rerunnable on a kept run: lab/swarm/eval.sh <run dir> [<wall seconds>]
set -uo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd); D=$1; wall=${2:-0}
LAB=$(cat "$D/lab-path"); R="$LAB/repo"; base=$(git -C "$R" rev-list --max-parents=0 main)
: > "$D/timeline.jsonl"
for c in $(git -C "$R" rev-list --reverse --first-parent main); do
  git -C "$R" worktree add -q --detach "$LAB/chk" "$c" 2>/dev/null
  vis=$(cd "$LAB/chk" && node --test >/dev/null 2>&1 && echo green || echo red)  # before the hidden file is there
  mkdir -p "$LAB/chk/acceptance"; cp "$HERE/lab/swarm/acceptance.test.js" "$LAB/chk/acceptance/check.mjs"
  # the second cluster's oracle: the same tests on src2/ and locales/en2.json, named t11-t20
  [ "${CLUSTERS:-1}" = 2 ] && perl -pe "s{'\.\./src/'}{'../src2/'}g; s{'locales/en\.json'}{'locales/en2.json'}g; s/test\('t0(\d)'/test('t1\$1'/; s/test\('t10'/test('t20'/" "$HERE/lab/swarm/acceptance.test.js" > "$LAB/chk/acceptance/check2.mjs"
  acc=$(cd "$LAB/chk" && node --test --test-reporter=tap acceptance/check*.mjs 2>/dev/null | perl -ne 'print "$2:", ($1 eq "ok" ? "ok" : "fail"), " " if /^\s*(ok|not ok) \d+ - (t\d\d)/')
  printf '{"commit":"%s","subject":"%s","visible":"%s","acceptance":"%s"}\n' "$(git -C "$R" rev-parse --short "$c")" \
    "$(git -C "$R" log -1 --format=%s "$c" | tr -d '"\\' | cut -c1-90)" "$vis" "$acc" >> "$D/timeline.jsonl"
  git -C "$R" worktree remove --force "$LAB/chk"
done
git -C "$R" log --format='%h %s' "$base..main" > "$D/main.log"
git -C "$R" diff "$base" main > "$D/main.diff"
for f in $(git -C "$R" ls-tree -r --name-only main src/ src2/ 2>/dev/null); do git -C "$R" show "main:$f" > "$D/final-$(echo "$f" | tr / -)"; done
# D5: files of src/ that turn text into a slug on their own (a definition, or the slug regex inline); D2: the check written twice
slugs=$(git -C "$R" grep -l -E '\[\^a-z0-9\]' main -- src src2 | wc -l | tr -d ' ')
namereq=$(git -C "$R" grep -o "name required" main -- src src2 | wc -l | tr -d ' ')
merges=$(git -C "$R" rev-list --merges --count main)
python3 - "$D" "$wall" "$slugs" "$namereq" "$merges" <<'PY'
import json, sys, os
d, wall, slugs, namereq, merges = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
tl = [json.loads(l) for l in open(f'{d}/timeline.jsonl')]
ev = [json.loads(l) for l in open(f'{d}/events.jsonl')]
acc = lambda c: dict(x.split(':') for x in c['acceptance'].split())
tasks = sorted(acc(tl[0]))
final = acc(tl[-1])
undone = [t for t in tasks if any(acc(c).get(t) == 'ok' for c in tl) and final.get(t) != 'ok']
sess = {}
for t in tasks:
    try: j = json.load(open(f'{d}/sessions/{t}.json'))
    except Exception: j = {}
    last = (j.get('result') or '').strip().splitlines()[-1:] or ['']
    ends = [e for e in ev if e.get('ev') == 'session-end' and e.get('task') == t]  # claude's duration_ms is sometimes a few seconds for a long run
    sess[t] = dict(verdict=last[0][:160], turns=j.get('num_turns'), cost=j.get('total_cost_usd'), secs=round(ends[-1]['secs']) if ends else None)
rc = {}
for e in ev:
    if e.get('ev') == 'ship-exit': rc.setdefault(e['wt'].split('.')[-1], []).append(e['rc'])
ran = [t for t in tasks if os.path.exists(f'{d}/sessions/{t}.json')]
host = [json.loads(l) for l in open(f'{d}/host.jsonl')] if os.path.exists(f'{d}/host.jsonl') else []
ships = sum(len(v) for v in rc.values()); e4 = sum(v.count(4) for v in rc.values())
res = dict(wall=wall, tasks=len(ran), accepted=sum(final.get(t) == 'ok' for t in ran), acceptance_final=final, undone=undone,
           red_main_commits=sum(c['visible'] == 'red' for c in tl), main_commits=len(tl) - 1, merge_commits=merges,
           slug_files_in_src=slugs, name_required_in_src=namereq, ship_runs=ships, ship_exit4=e4, ship_exit_codes=rc, sessions=sess,
           cost_usd=round(sum((s['cost'] or 0) for s in sess.values()), 2),
           host_peak=dict(claude=max((h['claude'] for h in host), default=0), rss_mb=max((h['rss_mb'] for h in host), default=0),
                          cpu=max((h['cpu'] for h in host), default=0)))
json.dump(res, open(f'{d}/result.json', 'w'), indent=1, ensure_ascii=False)
print(json.dumps({k: v for k, v in res.items() if k not in ('sessions', 'acceptance_final')}, ensure_ascii=False))
for t, s in sess.items(): print(f"  {t} {final.get(t)} rc={rc.get(t)} {s['secs']}s ${s['cost'] or 0:.2f} | {s['verdict'][:110]}" if s['secs'] is not None else f"  {t} {final.get(t)} (no session)")  # codex reports no cost
PY
