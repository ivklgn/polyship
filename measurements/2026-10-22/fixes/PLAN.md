# Improvements: candidates, predictions, written before the before/after runs (2026-10-22, evening)

Pareto of the raw events (`lab/pareto.py`): exit 4 is the largest cost wherever there are conflicts (real agents N = 10:
47 % of ship.sh time; stand N = 20: 29 % of time, 17 % of suite runs); then R6 (H: 11 % of time, 15 % of suites), D1
stale-branch reds (H.retry: 31 % of time, 43 % of suites), the tests before the queue (N = 30, no conflicts: 45 % of time).

| candidate | cost | weakens | decision |
|---|---|---|---|
| E4: ship.sh lets another session's merge through the fence (a chain of moves merge.sh recorded under its lock) | small: a moves file, an awk walk | an agent that forges a line in .git/wt-merge.moves passes; the fence is against mistakes | build |
| R7: remove a stale target ref lock / packed-refs.lock under the lock, like R5 | tiny | a git command stopped (not killed) for 60 s holding the ref lock | build |
| R6: the agent names a duplicate it skipped in merge-dropped; only that commit is excused | small; a prompt line | an agent that names a commit it should have kept | build. A content check (applying the commit changes nothing) was tried first and does not fix the measured case: the duplicate's code differs, the 3-way merge conflicts |
| R9/D1: ship.sh tests the branch rebased onto the current target | small; a rebase outside the lock, aborted on conflict | the branch is rewritten before the queue (the merge rewrites it anyway) | build |
| no tests before the queue | none: `SHIP_TEST=true` already does it | red branches then hold the lock (H: 23 % of suites were red before the queue) | document, keep the default |
| red intermediate commits: `rebase --exec` per commit, or squash the fix-ups | suite runs x commits, or the intent in the bodies | | not built: a history policy, the owner's call |
| batched merges for slow suites (lab/merge-batch.sh) | large | a red batch needs a bisect | not built here: model only |
| D3/D5 (a behavior changed under a green gate, duplicate code) | | | not the queue's: the review step and the adopter's tests |

Predictions for the same seeds, before (bin/ at 08e7423) and after:
- exit 4 per landed branch: N = 10: 35 % -> 0; N = 20: 40 % -> 0 (the stub never moves the target itself).
- R6 loops (sessions that give up after >= 3 exit-5 stops): ~25 per 100 runs at N = 10 -> 0.
- D1 consumers stuck with their provider on main (DEP_POLICY=retry): ~15 per 30 runs -> 0.
- R7: stuck runs -> 0 (rare: ~1 in 230).
- suite runs per landed branch: N = 10 about -25 %, N = 20 about -15 % (the tests before the queue of every rerun).
- p95 lock wait: not worse (+-15 %). Time to land p95: -5 to -20 %.
- violations: 0 after, in every campaign (rule of three at 100 runs: bad-run rate < 3 %).

## Amendment, before the measured runs

The first start of the campaigns (stopped after ~10 runs, not used) showed a second R6 shape: the duplicate landed
first with a different patch, and the original's rebase dropped its commit as empty by itself, with no conflict and
so no agent to name it. The content check (applying the commit to the target changes nothing) handles exactly that
shape, so it is back, next to merge-dropped for the conflict shape. Replay `R6b` in lab/recover.sh: exit 5 on the old
bin/, 0 on the new. The stand's stub agent now names a commit it skips as empty (lab/resolve.sh), as ship.sh's prompt
asks; old bin/ ignores the file, so before and after run the same stand. Predictions unchanged.
## note: C10.ship.after was rerun after R9b; the first start was stopped
## note, the night of 2026-10-23 (1)

lab/resolve.sh skipped "empty" commits after any stop with the index at HEAD, including a rebase stopped by a SIGKILL
(no conflict): 2 violations of the after side (C10.lock seed 7068 s3, C20.ship s10) are this stub defect (kept labs:
"interactive rebase in progress", "a git operation is already in progress"). Fixed: only after a real conflict. C10 and
C20 ran with the old stub on both sides; C30 (both sides) with the fixed one, started in parallel with C20.
## note, the night of 2026-10-23 (2)

The fence had a race (a merge between its fast-forward and its moves line: 20 of the 26 exit 4 left in C10.ship.after);
replay R8 mid-merge, fixed by waiting for the merge lock before the verdict. The after side of the ship campaigns read
bin/ live, so C10.ship, C20 and C30 after are rerun on a frozen copy (/tmp/bin-after, bin-after.sha); the earlier
after files are kept as *.superseded.*. C10.lock.after stands: merge.sh and lib.sh did not change after it started.
## note, the night of 2026-10-23 (3)

C20.ship.after (frozen copy 1) had 2 violations, both a session SIGKILLed inside `git rebase --continue`: the rebase
stays open with refs/heads/<branch>.lock, so it cannot be finished, and ship.sh said "on HEAD". The same on old bin/
(not a regression); my earlier note blamed the stub for one of these (C20 s10) and that was wrong for ship mode.
Replay R10, fixed in ship.sh (old locks of an open rebase removed, the message names the rebase). The after side of
the ship campaigns is rerun on frozen copy 2 (bin-after.sha); copy 1 files are *.superseded2.*.
## note: bin/ship.sh after the frozen copy 2 changed only in header comments (exit 4 wording, SHIP_ROUNDS listed)
