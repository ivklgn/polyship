# Measurements, 2026-10-21 and 2026-10-22

Question: do many sessions, each in its own worktree, with many overlapping edits, reach the target branch
through `merge.sh` / `ship.sh` without lost work, a red target, or a stuck queue? Measured on the code taken
from hotpot2 at `b1bbcfc` ("old") and on this repository after the fixes below ("new"). macOS 26, git 2.50.1,
Worktrunk 0.80.0, bash 3.2.

## Verdict

The old flow is safe for the target branch but not for the sessions: a SIGKILL at the wrong moment either
loses a branch's commits while reporting success, or blocks every later merge of the same files until a human
repairs the main checkout. The mkdir lock lets two holders in under contention and can hang forever. All three
are fixed and re-measured; no invariant failed on the new flow in 280 randomized runs (1 680 sessions).
A code review on 2026-10-22 and a first run at N = 10 found three more: exit 5 could come from a test runner
instead of lost commits, a change already on the target was reported as lost, and an `index.lock` left by a
killed git command stuck a session. After those fixes (`45941e8`): 0 violations in 200 runs at N = 10
(2 000 sessions), and every failure has a deterministic replay in `lab/recover.sh`.
A real agent resolved 10 of 10 real monorepo conflicts in one round; 2 of 10 resolutions lost something a
human kept, which only the project's pre-merge tests can catch.

## Invariants and thresholds (set before the runs)

Per run (`lab/race.sh`): no edit of a landed branch missing on the target; every first-parent commit of the
target passes the deterministic suite; every branch not on the target has a valid reason (a semantic
conflict with the target, an owner stop); the target is linear; the lock is free at the end; no two
pre-merge suites at once under the lock; no session past 300 s; a branch lands within K = 12 attempts
(`TRIES`) or has a valid reason. Pass: 0 violations in ≥ 100 runs (rule of three: bad-run rate < 3 % at 95 %).
The plan said N = 5 and N = 10; the runs used N = 6 (A, D, E) and N = 10 (G). Lock checks (`lab/lock.sh`): 0
failures per check.

## Randomized race (`lab/race.sh`)

6 sessions per run started within 3 s; each edits 2 random lines of 4 shared 6-line files (≈ 0.7 textual
conflicts per session); 10 % flaky suites, 15 % in a semantic conflict, 15 % (D) or 50 % (E) SIGKILLed once
at a random moment; 0.5 s suite; the stub agent resolves a conflict by keeping both sides after 0–2 s.
Same seeds for old and new. `bare` = `wt merge` without the lock, from campaign A.

| campaign | flow | runs | landed | violations | attempts p95 | suite runs / landed | lock wait p95 | time to land p95 |
|---|---|---|---|---|---|---|---|---|
| A | bare | 100 | 587/600 | 0 | 6 | 2.57 (1 006 suites overlapped) | – | 9.0 s |
| D | old lock | 100 | 588/600 | 0 | 4 | 1.34 | 8.0 s | 14.3 s |
| D | new lock | 100 | 586/600 | 0 | 4 | 1.39 | 2.8 s | 9.2 s |
| D | old ship | 100 | 582/600 | 0 | 2 | 2.75 | 6.0 s | 13.1 s |
| D | new ship | 100 | 590/600 | 0 | 3 | 2.64 | 2.2 s | 9.2 s |
| E (50 % killed) | old lock | 40 | 229/240 | **3 (stuck main checkout, seed 2039)** | 4 | 1.62 | 8.0 s | 13.6 s |
| E | new lock | 40 | 235/240 | 0 (1 re-sync done) | 4 | 1.38 | 2.6 s | 9.5 s |
| E | old ship | 40 | 235/240 | 0 | 3 | 2.90 | 6.0 s | 13.1 s |
| E | new ship | 40 | 233/240 | 0 (1 re-sync done) | 3 | 3.13 | 1.9 s | 9.3 s |
| F (N = 10) | `091976c` lock / ship | 43 / 51 (stopped) | 417/430, 489/508 | **ship: 1 stuck session (R5, seed 3017)**; 1 timeout caused by the operator (a stray `pkill sleep`, seed 3047) | – | – | – | – |
| G (N = 10) | final lock | 100 | 968/1000 | 0 | 5 | 1.45 | 7.2 s | 24.4 s |
| G (N = 10) | final ship | 100 | 964/1000 | 0 | 3 | 3.01 | 4.3 s | 19.6 s |

Not landed = semantic conflicts, refused by design (checked per branch). `ship` runs the tests once before
the queue, so it costs about one more suite run per branch than `lock`. Campaign A on the old flow, earlier:
**2 lost edits** (ship, seed 1016) and **3 sessions stuck** (lock, seed 1003), plus overlapping suites at lock
seeds 1043, 1061, 1062 and ship seed 1086; each of these runs had a SIGKILLed attempt, so they are most
likely orphan suites of killed merges (that stand had no orphan label yet; inferred from the timelines, not
proven). `A.lock` holds 84 complete runs (the 85th was cut by a time limit). Campaigns B and C were stopped by a
laptop sleep and are not used.

`ship.sh` exit 4 (the target moved while its agent resolved a conflict, here always another session's merge):
84 (old) and 120 (new) stops per ~590 landed branches in D (N = 6), 327 per 964 in G (N = 10): 14–20 % of
branches at N = 6 and about a third at N = 10 need one more `ship.sh` run. The cost grows with the number of
sessions; whether to let another session's fast-forward through is the owner's call (the guard is a fence
against the agent).

## Failures found and fixed

| | found by | mechanism | fix | check |
|---|---|---|---|---|
| R1 lost commits reported as merged | race A, ship seed 1016 (reflog: `rebase (start)` → `rebase (finish)`, no pick) | SIGKILL inside `git rebase` after the todo save, before the pick; `git rebase --continue` then finishes with nothing picked; the branch sits on the target and `ship.sh` said "already on main", exit 0 | `merge.sh` records the tip before each merge; landed = every recorded commit on the target by author, author date, subject; else exit 5 with `git reset --hard <tip>` | `lab/recover.sh` R1: old exit 0, new exit 5, restore lands the work |
| R2 stuck queue | race A lock seed 1003; E old lock seed 2039 (32 refusals) | SIGKILL of `wt merge` between `update-ref` and the sync of the main checkout; its index stays at the old target; every later merge of those paths: "conflicting uncommitted changes"; a commit there reverts merged work | under the lock, `merge.sh` finishes the sync when the main checkout's index is exactly a recent target that is an ancestor of the target (a forward move; an owner's `git reset --soft` also leaves the index at a recent target, but behind it: found by hotpot2's review, B1) | `lab/recover.sh` R2: old exit 1, new lands, owner's staged file kept; E new: 1 re-sync, 0 stuck |
| L1 two holders | `lab/lock.sh` T1, 20 waiters | mkdir lock, stale takeover: two waiters read the dead pid, one removes the lock the other just took | `flock(2)` on a file, released by the kernel | old T1 **8/40 fail**; new 0/40 (rechecked 2026-10-22, see the note below) |
| L2 hang | T3; T2 | a dead holder's pid reused by a live process blocks forever (10/10); a kill between `mkdir` and the pid write leaves a lock nobody takes (old T2 1/300) | flock: no pid | new T3 0/50, T2 0/300 (rechecked) |
| L3 slow takeover | T5 | 2 s polling | flock wakes the waiter | takeover p50 1.73 s (old, rerun) → 0.06 s (final) |
| L4 lock held by a daemon | review, tests lane | a test daemon inherits fd 9 and holds the flock after the merge | `9>&-` on every child of `merge.sh` | `lab/lock.sh` T6: 0/30; without `9>&-`, 3/3 fail |
| B1 exit 5 from a test runner | review, design lane; wt `src/git/error.rs` passes a hook's code through | pytest exits 5 when it collects no tests: read as "commits lost" | `merge.sh` turns `wt merge`'s 5 into 1; `MERGE_PREPARE` failure is 1 | `lab/recover.sh` R4: 091976c exit 5, final exit 1 |
| B2 duplicate change called lost | review, design lane | the same change from two sessions: the second rebase drops it as applied; `landed` said exit 5 and its advice looped | only commits `git cherry` marks `+` can be lost | `lab/recover.sh` R3: 091976c exit 5, final exit 0 |
| R5 stale index.lock | race F, ship seed 3017 (`evidence/R5-stale-index-lock-seed3017.txt`) | a SIGKILL during the rebase leaves `.git/worktrees/<wt>/index.lock`; 11 more merges fail "File exists" | under the lock, an `index.lock` older than 60 s in the worktree or the target's checkout is removed; a younger one stops with its path | `lab/recover.sh` R5 (fresh: exit 1; old in the worktree or the target checkout: lands) |

Old-lock numbers: `lock/old-mkdir-rerun-2026-10-22.txt` (T3 10/10, T5 1.73 s; the first run's output was not
kept, and its file was empty until this rerun). Final lock numbers: `lock/final-45941e8.txt` (every check 0/30,
T1 with 20 waiters 0/40, T2 0/300).

Correction, 2026-10-22: `lab/lock.sh` copied only `merge.sh` into its lab. Once `merge.sh` sourced `lib.sh`
(commit `91cd143`), that copy failed at once and every lock check passed with no merge run: the "new T2 0/300"
of campaign E and this repository's pre-merge gate at `0b4ea0c` proved nothing. The flock numbers measured
before `lib.sh` were real. `lab/lock.sh` now copies `lib.sh` and fails a rep in which the stub `wt` was not
entered (a broken `merge.sh` gives FAIL 2/2). Rechecked with it: every check PASS, T1 with 20 waiters 0/40,
T2 0/300 (`measurements/2026-10-21/lock/new-flock-recheck-with-lib.txt`). A second vacuous path came with
`45941e8`: `lib.sh` asks `wt` for the default branch, the lab's stub `wt` answered nothing, `merge.sh` exited 2,
and the stub counted that call as an entry. The stub now answers only `wt merge` and the lab sets
`MERGE_TARGET`; the final numbers above were measured after that.

Known and left: a SIGKILLed `wt merge` leaves its pre-merge suite running (Worktrunk runs hooks in their own
process group, `src/shell_exec.rs`), next to the next holder's: 1–9 per campaign, counted apart. The target
is never at risk (Worktrunk's fast-forward is a compare-and-swap `update-ref`).

## Real conflicts with a real agent (`lab/replay.sh`)

Raw material: a private TypeScript monorepo (pnpm, Next.js), 81 MR back-merges (2026-05 → 2026-10) whose parents conflict, each with the
human's resolution. 10 picked across shapes: one hot registry file, components, 2–3 files, 7–9 commit
branches, 6 translation JSONs, `pnpm-lock.yaml`. `ship.sh` rebased the MR onto master and called Claude
on the conflict (no MCP servers, no remote, no tests: dependencies are not installed in the lab).

| result | cases |
|---|---|
| landed, one agent round | 10 / 10 (27 s – 20 min; median ~100 s) |
| identical to the human on the conflicted files | 5 |
| equivalent (lockfile: hand-merged the one changed dependency; same entries as parsed YAML) | 1 |
| agent better: the human's merge lost master's fix, or left a duplicate declaration fixed one commit later (the agent's file equals that fix byte for byte) | 2 |
| agent worse: a semantic conflict needed a new `layout.tsx` the human added; 7–8 translation keys from master dropped in 6 locales | 2 |

The judgments of the four differing cases were made by a separate read-only agent and spot-checked; nothing
was built. The raw replay data (paths, commit subjects, agent logs of that monorepo) is not published. The 20-minute case is the agent running the monorepo's `tsc` on its own.

hotpot2's own history (45 commits, 231 pairs at distance ≤ 6): 84 pairs could have been parallel, 0 of
them conflict textually. Its sessions overlap far less than the stand assumes.

## What this does not show

- Real test suites in the gate: the stand's suite is a 0.5 s sleep. The queue cost grows with the suite;
  see the load estimate in README.
- The agent with the project's tests: the two "agent worse" cases are what the pre-merge gate must catch.
  Whether the monorepo's tests catch dropped translation keys or a missing layout is not measured.
- Linux, Git for Windows, Superset and Conductor sessions; server-side integration (merge requests).
- The stub agent always resolves; real-agent behaviour under concurrency (exit 4 loops, owner stops) is
  measured only on single replays.
- The pid-namespace hypothesis of the plan (a holder in another container): not measured. flock has no pid, but
  flock across bind mounts or network file systems is not checked.
- R5's removal path did not occur by itself in G (0 stale locks removed); it is guarded only by `lab/recover.sh` R5.
- `lab/race.sh` is a smoke and a measurement, not a regression guard: a seed fixes the plan, not the interleaving,
  and a reverted fix can pass a rerun of its own failing seed (shown for R1 by the review). The guards are
  `lab/recover.sh` and `lab/lock.sh`.

# Capacity and dependent work, 2026-10-22

Questions: how many sessions can the owner keep running through polyship at once, and what happens when ~10
sessions work at once on things that depend on each other? Raw data, commands and the plan written before the runs:
[2026-10-22/](2026-10-22/README.md), [PLAN.md](2026-10-22/PLAN.md). bin/ is unchanged from `main`. macOS 26, 10 cores, 24 GB.

## Verdict

- The merge lock is not what limits the owner on hotpot2: the model, checked against the stand, keeps the p95
  lock wait under 15 s up to 30 sessions. The limits are the owner (latency rises past 4 other open sessions),
  hotpot2's own suite (red in 1 of 8 and 2 of 16 runs when 4 or 8 run at once: "terminating connection due to
  administrator command" on the shared PostgreSQL; mechanism not proven) and, with tightly coupled tasks, exit 4.
  Comfortable: 4-5 sessions, bounded by the owner, not by polyship.
- On the monorepo (suite 183 s, 1.7x slower with 2 at once, 3.5x with 4) the lock and the CPU are the limit:
  3-4 sessions on a typical day, 3 on a busy one (SLO S1, p95 lock wait <= 5 min).
- Dependent work never lost a change and never made the target's tip red: 0 lost edits, 0 red tips, 0 stuck locks in
  230 stand runs (2 300 sessions) and 3 real-agent runs (30 sessions). It costs something else:
  two new failure shapes (R6 a false "commits lost", R7 a stuck queue), red intermediate commits, and changes that
  the gate cannot see: a duplicate implementation (3 of 3 runs) and a behavior of one task silently changed by
  another (2 of 3 runs).

## Inputs from the owner's own data (`lab/sessions.py`, `lab/suite-time.sh`, monorepo git history)

| input | value |
|---|---|
| sessions open at once, minutes since 2026-09-01 | 1: 7 939, 2: 2 869, 3: 805, 4: 99, 5: 65, 6: 43, 7: 2; daily peak 1-7 |
| owner latency p50 by other open sessions | 0: 1.2 min (n 634), 1: 1.3 (468), 2: 1.6 (239), 3: 1.1 (39), 4: 4.5 (24), 5+: too few |
| task cycle: first prompt to first commit | p25 8 min, p50 29 min, p75 99 min (119 sessions) |
| real use of ship.sh outside polyship's own development | about none: the ship calls in the transcripts are polyship's development |
| hotpot2 `pnpm test` | 15.7 s alone; k = 2: 16 s; 4: 12.5 s; 8: 35 s (p50); red under parallelism 1/8 (k = 4), 2/16 (k = 8), 0/6 below |
| monorepo `pnpm ts-check && pnpm test` | 183 s alone; 297-326 s with 2 at once; 612-672 s with 4 |
| monorepo MRs with a conflicting back-merge | 169 of 1 079 (15.7 %) over 6 months, flat in the branch's age; hot files: translation.json, index.tsx, .sync-state.json, default.po, pnpm-lock.yaml |
| hotpot2 pairs A→B at distance <= 6 (`lab/pairs.py`, the real suite) | 279: chain 134, textual 31, clean and green without A 114, semantic (clean but red without A) 0. Probe: an emptied source file turns the suite red (11 fails) |

The stand's 0.7 conflicts per session (campaigns A-G) is far above both real histories: hotpot2's dependent work
almost always touches the same lines, so polyship shows it as a conflict instead of letting it through.

## The model of the queue, checked (`lab/queue.py`, `lab/xfit.py`)

| check | measured | model | pass (<= 20 %) |
|---|---|---|---|
| G (N = 10 bursts): mean wait vs a FIFO replay of the same arrivals | 1.94 / 3.02 s | 1.85 / 2.93 s | yes; the lock is idle 1-1.5 % of the waiting time |
| Q, N = 30, rho 0.26 / 0.53 / 0.72: mean wait vs FIFO replay | 0.33 / 0.68 / 0.56 s | 0.32 / 0.66 / 0.54 s | yes; idle 0.5-0.6 % |
| Q: Pollaczek-Khinchine mean wait | as above | 0.46 / 1.48 / 3.23 s | no: an upper bound on a finite window |
| Q: simulation, p95 wait | 2.14 / 3.31 s | 2.3 / 4.9 s | rho 0.26 yes; rho 0.53 no (+48 %, pessimistic) |
| X, N = 4/8/12/16/20: p95 wait | 0.01/0.83/1.06/1.57/2.23 s | 0.5/0.8/1.0/1.6/2.0 s | yes from N = 8 |
| X: exit 4 per landed branch | 0/7/15/27/40 % | 1/6/12/17/25 % | yes to N = 12; N >= 16 no (-40 %, optimistic) |
| swarm (real agents, N = 10): exit 4 per landed / p95 wait | 77 % / 21 s | 54 % / 41 s | no |

So the lock is an ideal single server; the model's waits are a pessimistic bound and its exit-4 share an
optimistic one past 12 sessions or with real agents (conflicts there concentrate on pairs of tasks, the model
spreads them evenly). Capacity below is read with that in mind (`2026-10-22/capacity-predictions.txt`):

| project, day | p95 lock wait at N | sessions with exit 4 at N | comfortable N |
|---|---|---|---|
| hotpot2, W = 30 min, p-conflict 0.05 | 10: 6 s, 20: 12 s, 30: 15 s | 30: 1 % | lock: 30+; owner: 4-5 |
| hotpot2, W = 8 min, coupled tasks (p 0.7) | 10: 14 s, 20: 30 s | 10: 9 %, 15: 14 % | 8-10 (S2), lower given the model's bias |
| monorepo, W = 30 min, p 0.157, agent 100 s | 4: 233 s, 5: 373 s, 6: 514 s | <= 1 % | 4 |
| monorepo, W = 8 min | 3: 262 s, 4: 549 s | <= 1 % | 3 |

## Dependent work: stand (`lab/race.sh` P_DEP / P_DUP, N = 10)

| campaign | runs | landed | violations | what they are |
|---|---|---|---|---|
| H ship | 100 | 941/1000 | 25 | all R6 loops |
| H lock | 100 | 944/1000 | 29 | all R6 loops |
| H.retry ship (the stub never rebases) | 30 | 262/300 | 32 | 15 D1 consumers whose provider was on main, 8 R6 loops, 9 in one R7 run |
| Q (no conflicts) | 24 | 720/720 | 0 | |
| X (conflicts, no faults) | 100 | 1 200/1 200 | 0 | |

- D1 ordered. With ship.sh a dependent never holds the lock with a red suite: 387 red runs before the queue, 0
  under it (lock mode: 185 red suites under the lock). But ship.sh tests the branch as it is, not rebased: once the
  provider lands, the consumer stays red until someone rebases it. PLAN.md expected "lands on a retry"; that holds
  only with DEP_POLICY=rebase (H: 2 dep-missing, both valid) and fails without it (H.retry: 15 of 17).
- D2 duplicate. Identical patches land (R3). A duplicate that went through a conflict is R6 (below): 282 exit-5
  stops in H.ship, 225 in H.lock.
- D3 incompatible (the api remove/use pair): refused with the target green in every run.
- A token on main twice: 5 / 7 / 1 times, made by the stub's keep-both resolution of a duplicate; a measurement.

## Dependent work: real agents (`lab/swarm.sh`, 3 runs, 10 `claude -p` sessions each, $20.39)

| | s1 | s2 | s3 |
|---|---|---|---|
| tasks landed (the session ended SHIPPED) | 10 | 10 | 10 |
| hidden acceptance green on the final main | 9 | 9 | 10 |
| a task green when it landed, red at the end (undone) | t10 | t10 | – |
| first-parent commits of main red on the visible suite | 0/10 | 0/10 | 2/11 |
| ship.sh runs / exit 4 / exit 5 | 17/6/0 | 21/10/0 | 20/7/1 |
| src files that slugify on their own (D5; 1 is right) | 2 | 2 | 2 |
| "name required" in src (D2; 1 is right) | 1 | 1 | 1 |
| host peak: claude processes, RSS, CPU | 16, 6.3 GB, 1.7 cores | 19, 6.4 GB, 2.3 | 18, 5.2 GB, 1.4 |

- Every agent acted on every exit code as CLAUDE.md says (exit 4: rerun; exit 1: fix and rerun). 15 of 30 sessions
  hit exit 4 at least once, far over S2 (10 %); the 10 tasks started within 60 s and share files on purpose.
- D3 by a real agent: t09 made the currency a required argument and rewrote t10's `orderTotal(items)` into
  `orderTotal(items, currency)` with its test, so the gate stayed green while t10's specified call broke (2 of 3
  runs). Nobody stopped with OWNER DECISION NEEDED; the agent chose the product behavior. A rename (t03/t04) and two
  entries in one registry and translation file (t05/t06) came through in 3 of 3 runs.
- D5: t02 needed t01's `slugify`, did not find it on its base, and wrote its own inline (3 of 3 runs).
- Red intermediate commits: a session red after the rebase (exit 1) adds a fix on top; merge.sh merges with
  `--no-squash`, so the red commit itself lands. The gate tests only the tip; the stand's "red" invariant held so far
  only because every stand branch has one commit.
- Not measured: the host past 10 real agents; the review step (SHIP_REVIEW=0 here).

## New failure shapes (fixed the next night: see "Improvements measured before/after" below)

| | found by | mechanism | replay |
|---|---|---|---|
| R6 a false "commits lost" | swarm s3 t08; H (54 loops) | the duplicate landed after a conflict, so its patch differs; the original's rebase stops, the right resolution is "already there", the commit becomes empty and is skipped; `landed` matches by patch or by author, date and subject and finds neither: exit 5. Following its advice reproduces the same conflict (the stub loops to its 12 tries); the real agent took "dropped on purpose", which is also the path that hides a real loss | first a standalone script (exit 5, 3 of 3); now `lab/recover.sh` R6 |
| R7 a stuck queue | H.retry seed 4020 | a merge SIGKILLed while git moved the target leaves `refs/heads/main.lock`; every later merge: "cannot lock ref", exit 1; merge.sh removes a stale index.lock (R5) but not a ref lock. 1 of 230 runs with kills; 9 sessions gave up, main never moved | first a standalone script (exit 1, 2 of 2); now `lab/recover.sh` R7 |

## What this does not show

- The owner latency rise past 4 other sessions rests on 24 answers; past 5 on 5. The comfortable 4-5 is the
  owner's own history, not a measured limit of attention.
- The capacity model has no review step, no agent run before the queue, and treats conflicts as independent per
  merge; the swarm shows the last one is wrong for coupled tasks.
- hotpot2's red suite under parallelism: seen, its mechanism not proven (the PostgreSQL log showed nothing).
- The monorepo's capacity assumes its suite is the gate; its real MR flow (GitLab) does not use polyship.
- Linux, more than 10 real agents, Codex sessions.

# Improvements measured before/after, 2026-10-22 and 23

Plan, candidates and predictions written before the runs, with every later amendment: [fixes/PLAN.md](2026-10-22/fixes/PLAN.md).
Before = bin/ at `08e7423`; after = the frozen copy in [fixes/bin-after.sha](2026-10-22/fixes/bin-after.sha). Same
stand, same seeds, both sides (`lab/race.sh` P_DEP=20 P_DUP=20 DEP_POLICY=retry, default faults with 15 % of
sessions SIGKILLed once). Intervals: 95 %, bootstrap over runs (`lab/compare.py`).

## What changed in bin/

| | change | found by | replay |
|---|---|---|---|
| E4 | ship.sh lets another session's merge through its fence: merge.sh records every target move under its lock in `.git/wt-merge.moves`; a move goes through when the remotes and hooks are the same and every step is recorded, waiting for the merge lock when the last step may not be written yet. The agent moving the target, alone or under a later merge, is still exit 4 | Pareto: exit 4 was 47 % of ship.sh time with real agents at N = 10 | R8 (4 cases) |
| R7 | merge.sh removes an old `refs/heads/<target>.lock` and `packed-refs.lock`, as R5 does for index.lock | H.retry seed 4020: the queue never moved again | R7 |
| R6 | `landed` also accepts a commit whose change is already in the target's tree (the rebase dropped it as empty), and one the agent names in `merge-dropped` after skipping it as a duplicate (ship.sh's conflict prompt says so). A content check alone does not fix the real-agent case (other code, a 3-way conflict) | swarm s3 t08; H: 54 loops | R6 (3 cases) |
| R9 | ship.sh tests the branch rebased onto the current target; when that rebase conflicts, it skips the tests before the queue (the rounds resolve, the pre-merge hook tests under the lock) | H.retry: a dependent branch red forever on its old base | R9, R9b |
| R10 | ship.sh in a worktree with an open rebase removes that rebase's old locks (index.lock, refs/heads/<branch>.lock) and says a rebase is open, instead of "on HEAD" | C20 after, copy 1: a session killed inside `rebase --continue` | R10 |
| | ship.sh rounds 5 -> 10 (`SHIP_ROUNDS`): a run now sees more moves of the target | | |

`lab/recover.sh`: 72 checks pass on after; 30 fail on before (the new cases, each on main, master and develop).
`lab/lock.sh` REPS=5: every check passes. Not built: squash or per-commit tests for red intermediate commits (a
history policy), batched merges (model only, below), no tests before the queue (already `SHIP_TEST=true`).

## Stand, before -> after

| | N = 10 (100 runs) | N = 20 (100 runs) | N = 30 (50 runs) |
|---|---|---|---|
| violations (bad runs) | 117 (73) -> **0** | 268 (96) -> **0** | 210 (50) -> **0** |
| landed sessions | 848 -> 961 of 1 000 | 1 621 -> 1 916 of 2 000 | 1 196 -> 1 410 of 1 500 |
| exit 4 per landed branch | 0.37 [0.33, 0.41] -> 0 | 0.24 [0.22, 0.27] -> 0 | 0.27 [0.23, 0.30] -> 0 |
| suite runs per landed branch | 11.4 [9.7, 13.3] -> 3.0 [2.6, 3.5] | 12.2 [11.0, 13.4] -> 2.8 [2.5, 3.1] | 13.4 [11.9, 15.1] -> 3.3 [3.0, 3.7] |
| every session until it ends, p95 | 134 s -> 18 s | 134 s -> 24 s | 135 s -> 33 s |
| landed branches only: time to land p95 | 13.9 -> 15.8 s (+14 %) | 11.6 -> 21.6 s (+87 %) | 13.4 -> 29.5 s (+120 %) |
| lock wait p95 | 3.1 -> 3.6 s (+15 %) | 2.8 -> 4.7 s (+68 %) | 3.4 -> 7.6 s (+122 %) |
| run wall p50 | 136 -> 19 s | 157 -> 45 s | 174 -> 66 s |

lock mode, N = 10: violations 44 -> 1, landed 934 -> 962, exit-5 stops 296 -> 1; suite runs, waits and time to land
unchanged within the intervals. The one after violation is a stand defect (the stub skipped after a SIGKILL; fixed
in lab/resolve.sh, see PLAN.md). Before violations by shape: R6 loops 196, R9 stuck dependents 403, R10 after a kill 1,
and 6 sessions of one C10 lock run (seed 7061) where the queue stopped after a SIGKILL: two more merges landed, then
70 attempts failed and main never moved again; most likely R7, not proven (its kept lab was deleted).

The landed-only times and the lock wait got worse, and grow with N. This report first blamed survivorship (the before
side loses its slow branches). The paired comparison of the next day (`lab/compare.py --paired`, only branches that
landed on both sides of the same seed) refutes that as the main cause: the same branches land later too (p95 +10 s at
N = 20, +15 s at N = 30). The cause is load on the lock: 13-18 % more branches reach it, and a round after another
session's merge requeues at once where exit 4 used to pause the session. A latency-for-throughput trade; every session
still ends 4-7x sooner. Where the waste is now (`lab/pareto.py`, after): runs that end in exit 1
(red before the queue) are 10-21 % of ship.sh time and 38-55 % of suite runs: the stand's dependents waiting for
their provider, flaky and semantic branches.

## Real agents, before -> after (`lab/swarm.sh`, frozen copy 1: E4, R6, R7, R9 without R9b and R10)

| | N = 10 (3 runs -> 2) | N = 20 (1 run -> 1 run on copy 1, 1 on copy 2) |
|---|---|---|
| ship.sh runs per session | 1.93 -> 1.10 | 2.45 -> 1.10, 1.25 |
| sessions with exit 4 | 15 of 30 -> 0 of 20 | 12 of 20 -> 0, 0 |
| exit 5 | 1 -> 0 | 1 -> 0, 0 |
| hidden acceptance on the final main | 28/30 -> 20/20 | 20/20 -> 20/20, 20/20 |
| red first-parent commits (intermediate) | 2/31 -> 0/19 | 2/21 -> 1/19, 0/20 |
| swarm wall | 227-279 s -> 318-353 s | 395 s -> 349 s, 394 s |
| host peak at N = 20 | | 28-32 claude processes, 8.2-9.0 GB, 2.6-2.8 cores |

The second N = 20 run is on the final bin/ but for R10 (copy 2 differs only on a path a SIGKILL takes). Two more runs
on the final bin/ (f10, f20) hit the subscription's session limit at the start and count for nothing. t10 green on all
after runs is not evidence that E4 fixes D3: the order of t09 and t10 decides it, and 5 runs are few.

## The plan's predictions, checked

| prediction | measured | |
|---|---|---|
| exit 4 -> 0 (stand and real agents) | 0 everywhere | pass |
| R6 loops, R9 stuck dependents, R7 stuck runs -> 0 | 0 | pass |
| violations 0 in every campaign | 0 (ship), 1 stand defect (lock) | pass |
| suite runs per landed: -25 % (N = 10), -15 % (N = 20) | -73 %, -77 % | direction right, size wrong: the plan did not count the suite runs of R6 and R9 loops |
| p95 lock wait not worse (+-15 %) | +15 %, +68 %, +122 % | **fail** past N = 10 |
| time to land p95 -5 to -20 % | landed only +14 to +120 %; every session -75 to -87 % | **fail** as stated; the metric mixed in survivorship |

## Model what-ifs for slow suites (`lab/queue.py --batch`, `--pre 0`; not built)

Monorepo inputs (T 183 s, 1.7x slower with 2 suites at once, 3.5x with 4, task every 30 min, p-conflict 0.157):

| | p95 lock wait at N = 6 / 10 / 20 | comfortable N (<= 5 min) |
|---|---|---|
| as now | 569 / 2 138 s / – | 4 |
| no tests before the queue (`SHIP_TEST=true`) | 297 / 748 s / – | 6 |
| batches of 4 | 235 / 471 / 2 108 s | 6 |
| batches of 4 and no tests before the queue | 168 / 173 / 181 s | 20+ |

The first limit on a slow suite is the CPU the parallel tests before the queue take, the second the serial lock. A
batch that goes red needs a bisect, which the model does not count; at a 5 % red rate a batch of 4 fails about one
time in five.

## Still open

- Docs, vendoring and the git floor: done the next day (see "Review fixes" below).
- D3 and D5 are not the queue's to fix; red intermediate commits remain (tip-only gate with `--no-squash`).

# Review fixes and the final measurement, 2026-10-23

A deep code review of the changes above (Codex and Claude through polybrief, every
blocker checked by a probe) found three blockers in them, all now fixed, each with a replay in `lab/recover.sh` that
fails on the bin/ before it:

| | found by | mechanism | fix | replay |
|---|---|---|---|---|
| B1 | Claude worker; probe | `landed` took "applying the commit changes nothing" from merge-tree's tree without its exit code: on a modify/delete conflict the target's side stays, and a lost deletion read as landed (exit 0) | only a clean merge-tree counts | R6c |
| B2 | the judge and Claude, separately; probe | ship.sh's new rebase before the tests ran before any tip record: a kill inside it was R1 again, with "already on the target" and exit 0 | `record_tip` before that rebase | R1b |
| B3 | Claude worker; probe | merge.sh recorded any move of the target between its start and end, so a move someone else made while its fast-forward was refused passed ship.sh's fence | record only a move to this branch's own tip | R8b |
| Q1 | Claude worker (question) | the agent running merge.sh itself would pass the fence as a recorded move | ship.sh sets SHIP_AGENT_RUN for its agent; merge.sh refuses under it | R8c |

A new stand, `lab/kill-stress.sh` (one SIGKILL at a random moment of ship.sh, then the recovery its messages ask
for), found more states a kill inside the rebase before the tests leaves; each is fixed with a replay:

| probe | bin/ | landed / lost / stuck of 300 | what the lost or stuck ones were |
|---|---|---|---|
| 1 | B1-B3 + R10b | 290 / 1 / 9 | R1 aftermath with an old index.lock: the restore exit 5 names failed (R1c); the 9 stuck were counted as ok by this first version of the probe (rcs `2` twelve times in probe1.txt) |
| 2 | + R1c | 296 / 0 / 4 | a rebase that had moved the branch and was killed before its cleanup: --continue can never pass (R10c) |
| 3 | + R10c | 298 / 1 / 1 | R1 with the lost file left untracked: exit 2 hid exit 5 (R1d); an old HEAD.lock (R5b) |
| 4 | + R1d, R5b (final) | **300 / 0 / 0** | |

Raw lines: `2026-10-23/stress/probe1-4.txt`.

Final campaigns, same stand and seeds as above, the after side on frozen bin/ `df4badf` (B1-B3, Q1, R10b; without
R1c, R1d, R5b, R10c, which only change what ship.sh does at its start after a kill and are covered by the replays and
probe 4). N = 30 now has 100 runs per side (the before side's runs 51-100: seeds 7250-7299).

| | C10 ship | C10 lock | C20 ship | C30 ship |
|---|---|---|---|---|
| violations, before -> after | 117 -> 0 | 44 -> 0 | 268 -> 0 | 428 -> 3 (2 runs) |
| landed | 848 -> 967 | 934 -> 969 | 1 621 -> 1 916 | 2 363 -> 2 835 |
| exit 4 per landed branch | 0.37 -> 0 | – | 0.24 -> 0 | 0.26 -> 0 |
| suite runs per landed branch | 11.4 -> 2.9 | 1.9 -> 1.7 | 12.2 -> 2.6 | 14.2 -> 3.1 |
| paired time to land p95 | 13.9 -> 21.2 s | 19.9 -> 24.8 s | 11.5 -> 25.0 s | 13.7 -> 34.4 s |
| paired lock wait per branch p95 | 5.9 -> 11.0 s | 13.0 -> 16.4 s | 5.3 -> 13.9 s | 7.6 -> 20.2 s |

The three C30 violations: two edits of one session (seed 7204) lost in the R1c way, and one session (seed 7278) stuck
with an open rebase whose --continue cannot pass; both are states probe 4 recovers on the final bin/ (the stand's
stub does not run `git rebase --abort`, which ship.sh's message now names).

Timing caveat: the after side ran five campaigns at once, the before side four, so the after side ran on a busier
machine. Lock mode, whose algorithm hardly changed, is 24-34 % slower here, which bounds how much of the wait growth is
the machine. The criterion "p95 lock wait not worse" is not met, as on the first day: a branch waits longer for the
lock, while sessions land 14-20 % more branches and none is lost on the final bin/ in probe 4.

# Second review and the final check, 2026-10-23

A second deep review of the round above (Codex and Claude through polybrief, every blocker checked by a probe) found:

| | found by | mechanism | fix | replay |
|---|---|---|---|---|
| B1 | the judge; probe: `SHIP_AGENT_RUN=1 lab/recover.sh` failed 105 of 105 | the agent's marker reached every child process, so merge.sh refused in any repository: ship.sh's own review agent running the project's gate went red | the marker holds the repository's git common dir; merge.sh refuses only there | R8d |
| B2 | Claude worker; probe | exit 5 now came before "uncommitted changes", and the reset it names deleted the session's new uncommitted edit | exit 5 on a dirty tree also says `git stash -u` first; README and INSTALL say it | R1e |
| m1 | Claude worker | a commit slipped onto the target between merge.sh reading it and wt merge's rebase was recorded as this merge | record only a move with no more new commits than the branch brought | R8e |
| M2 | Codex worker | `lab/kill-stress.sh` counted a rep as ok when ship.sh had ended before the kill | such a rep is NOKILL, not ok | |

Every replay fails on the bin/ before its fix (R1e, R8d, R8e on `303f4d2`; R5b, now with a moved target, on a copy
without the HEAD.lock removal). Final bin/ `e63ffd8`, raw data in `2026-10-23/final2/`:

| check | result |
|---|---|
| lab/recover.sh | 108 / 108, also under `SHIP_AGENT_RUN=1` |
| lab/lock.sh, ship-checks.sh, vendor-checks.sh | pass |
| lab/kill-stress.sh, 300 reps | 299 landed, 1 NOKILL, 0 lost, 0 stuck |
| C10 ship, 100 runs, same seeds as before | violations 117 -> 0; landed 848 -> 951; suite runs per landed 11.4 -> 3.0; paired p95 time to land 13.9 -> 16.4 s |
| C10 lock, 100 runs | violations 44 -> 0; landed 934 -> 973; suite runs per landed 1.9 -> 1.5; paired p95 time to land 19.9 -> 22.0 s |

These C10 runs had only one other stand beside them (kill-stress), and their paired p95 grew by 2-2.5 s, not the 7 s
of the five-at-once run above: most of that gap was the machine. The rule's race run (RUNS=100 N=10, lock and ship)
is now on the final bin/; N = 20 and 30 were not rerun on it.

## 2026-10-26: third review, exit 0 with the work missing (uncommitted, on top of 71a78e9)

Fixes: ship.sh ends on `landed`, not ancestry (R11); `record_tip` keeps an earlier tip that HEAD does not contain (R12); the
identity match in `landed` needs the match's files to be a subset of the commit's (R13, R6d); an edited merge commit is
refused with 2 (R14); the fence sees remote URLs and `core.hooksPath` (R15); `lab/race.sh` draws its plan without a
subshell, so one seed gives one plan on bash 3.2 (R16). Pairs recorded before this change compare other plans (749 of
1000 matched sessions differed in the recorded conditions): their per-run numbers stand, "the same branches" does not.

| check | result |
|---|---|
| lab/recover.sh | 135 PASS, 0 FAIL |
| lab/race.sh RUNS=100 N=10 MODE=lock | 0 violations in 100 runs, landed 972, gave-up 28; time to land p50 10.2 s, p95 20.4 s; suite runs per landed 1.40 |
| lab/race.sh RUNS=100 N=10 MODE=ship | 0 violations in 100 runs, landed 971, gave-up 29; time to land p50 8.8 s, p95 16.4 s; suite runs per landed 2.43 |

The first run of the relaxed rule had 3 violations in 300 sessions: the strict file-set match read a commit that lost a
file the target already had as lost, and a session looped on exit 5 until it gave up (lock seeds 57587, 57593, ship 3779).
New seeds, not comparable with the C10 rows. Not rerun: lab/kill-stress.sh, N = 20 and 30, real Claude/Codex.

lab/kill-stress.sh on the fixed bin: REPS=150 and REPS=300 gave 149 ok + 1 NOKILL, and 299 ok + 1 STUCK; the baseline HEAD bin
gave 150 ok in 150. An intermediate state of this change also gave 2 STUCK in 100. All three STUCK reps are a git state a
SIGKILL leaves inside the rebase before the tests, which ship.sh does not repair: `CHERRY_PICK_HEAD` (+ `.lock`) with no
rebase open ("a git operation is already in progress", exit 1 in every round), or a half-written `rebase-merge/`. The
changed code does not run in that window, and 0 in 150 on the baseline cannot tell 0.5% from 0%: treated as a known
limit, about 3 in 550 kill reps, not as a regression. No LOST in 600 reps.

# 2026-10-26: readiness for many agents — push, merge commits, kill leftovers, Codex

Raw data: [2026-10-26/readiness/](2026-10-26/readiness/). Every real-agent run used Sonnet (Claude) or gpt-6-luna (Codex)
at effort low or medium, with ship.sh's review step on (`SWARM_REVIEW=1`, `SHIP_REVIEW_HOW` in plain words).

| | found by | mechanism | fix | replay |
|---|---|---|---|---|
| push | known limit | the target only moved locally, so a new worktree from `origin/<target>` started from stale code | `MERGE_PUSH=<remote>`: under the lock take the remote's target, merge, push; a rejected push puts the target back and merges again on top | R19-R19h |
| red | swarm, Sonnet, N = 10: 2 of 11 commits of main red, one a review fix | the gate tests the tip; `--no-squash` put every branch commit on the first-parent line | `wt merge --no-ff`: a merge commit whose tree the gate tested | R20 |
| stuck | kill-stress, about 3 in 550 | a kill inside the rebase before the tests left `CHERRY_PICK_HEAD` with no rebase, or a `rebase-merge/` without `head-name` | with HEAD on the branch and a clean tree, ship.sh clears them | R21-R21c |
| codex | swarm, Codex: 0 of 10 sessions could commit | Codex's workspace-write sandbox keeps a worktree's git dir read-only, even as a writable root (reproduced with `codex sandbox -P :workspace`, no model) | ship.sh runs its Codex agent without the sandbox, as it runs Claude | R22 |
| empty record | race PUSH=1 N = 10, seed 261050: origin behind main at the end | a SIGKILL while `record_tip` wrote `merge-orig` left it empty; it was never rewritten, so the next merge was not recorded and not pushed | an invalid record counts as none; written through a rename; the move test no longer needs it | R12b |
| killed merge | race PUSH=1 N = 10, seed 261035: nothing landed, every merge exit 2 | a SIGKILL after wt merge moved the target and before its moves line and push: the move looked like an owner's commit | `wt-merge.pending` holds the target and the branch before wt merge; the next merge.sh records a merge commit of that branch's tip on top of it and pushes it; an owner's merge commit is not taken (R19k) | R19i, R19k |
| unpushed shipped | review 3: ship.sh said "already on the target" (0) for a merge the remote lacked | the early exit tested the local target only | with MERGE_PUSH it runs merge.sh first, which pushes | R19j |
| moves | swarm, Sonnet, N = 20, push: 7 exit 4; local main left ahead of origin, every later merge exit 2 | a conflict agent's extra commit failed the "no more commits than the branch brought" check, so the merge was not recorded; a merge ending 5 was not pushed | the merge commit's parents prove the move; a moved target is pushed also on 5 | R8f, R19h |

| check | result |
|---|---|
| lab/recover.sh (macOS) | 195 PASS, 0 FAIL; R19-R22, R8f, R12b, R19i-R19k fail on the bin/ before their fix |
| lab/kill-stress.sh REPS=300 (final bin/) | 299 ok, 1 NOKILL, 0 STUCK, 0 LOST (an earlier 300 with R21 only: 300 ok) |
| REPS=5 lab/lock.sh, 50 times in a row | 50 pass (the one failure seen in a gate earlier: not reproduced, cause unknown) |
| Linux (Debian trixie, bash 5.2, git 2.47, wt 0.80, Docker; final bin/) | recover 195 PASS (R22 imitates Codex's sandbox there), lock, ship-checks, vendor-checks pass; race N = 10: lock, ship, ship+push 20 runs each, 0 violations |
| lab/race.sh RUNS=100 N=10 MODE=lock (final bin/) | 0 violations; landed 977, gave-up 23; time to land p50 10.1 s, p95 20.3 s; suite runs per landed 1.34 |
| lab/race.sh RUNS=100 N=10 MODE=ship | 0 violations; landed 977, gave-up 23; p50 9.4 s, p95 18.1 s; suite runs per landed 2.39; exit 4: 0 |
| lab/race.sh RUNS=100 N=10 MODE=ship PUSH=1 | 0 violations (origin equal to main in every run); landed 976, gave-up 24; p50 9.9 s, p95 18.9 s; 2.39 |
| swarm Sonnet medium, N = 10, review on (bin/ before push and `--no-ff`) | 10/10 accepted; exit 4: 0 of 11 ship runs; 2 of 11 main commits red (the finding above); $1.35 |
| swarm Sonnet medium, N = 20, review, push (bin/ before R8f, R19h) | 17/20 accepted; 7 exit 4; main left ahead of origin (the finding above); $2.93 |
| swarm Sonnet low, N = 20, review, push (final bin/) | 20/20 accepted; 0 red first-parent commits; exit 4: 0 of 36 ship runs; origin = main; host peak 33 claude processes, 8.3 GB, 3.2 cores; $2.81 |
| swarm Codex gpt-6-luna low, N = 10, review, sessions without sandbox (bin/ with R22) | 4/10 accepted; 0 red, 0 exit 4. Of the other 6: 4 ended their own turn while ship.sh waited for its review agent ("ship script is awaiting review"), 1 got exit 1 because its review agent gave no verdict, 1 reported SHIPPED with no ship.sh run; the agent instructions now say to wait for the exit code (not rerun) |

The stand's scripted agent now aborts a rebase that `--continue` refuses (a kill after git staged a pick), as ship.sh's message says (race PUSH=1 seed 261042: one session gave up on it). One replay invocation hung after 8 clean runs and did not repeat under a trace; cause not found.

The final lock run is on the stand with one more fix: an overlap whose inner suite belongs to a SIGKILLed merge (its wt hook started the suite 0.1 s after the kill freed the lock, lock seed 261069) counts as an orphan, as the entering branch's already did. Earlier runs of this round, on bin/ before R12b and R19i, are not in the table: they found those two.

Not measured: Codex past this one run, or with a stronger model; more than 20 real agents; a real remote over the network
(the stands use a bare repository on disk); Git for Windows.
