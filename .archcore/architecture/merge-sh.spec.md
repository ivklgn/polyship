---
title: "merge.sh — the locked merge into the target branch"
status: draft
tags:
  - "merge"
  - "spec"
---

## Purpose & Scope
The contract of `@bin/merge.sh`: one session at a time merges the current worktree's branch into the target branch, and the exit code tells the caller whether the branch landed with all its commits. Depended on by `@bin/ship.sh` (its merge rounds), by the adopters' task-runner aliases, and by `@lab/recover.sh`, `@lab/lock.sh`, `@lab/race.sh`. Out of scope: the rebase and the pre-merge hook themselves (Worktrunk `wt merge`), the review and the conflict rounds (ship.sh).

## Surface
- Invocation: `merge.sh [wt-merge flags]`, inside the worktree whose branch is to land; no target argument.
- Inputs: `MERGE_TARGET`, `MERGE_PUSH`, `MERGE_PREPARE`, `MERGE_STALE_INDEX_LOCK`, `MERGE_EVENTS` (headers of `@bin/lib.sh`, `@bin/merge.sh`).
- Lock: `<git-common-dir>/wt-merge.lock`, held by `flock(2)` on fd 9; its text names the holder for the waiting message.
- Tip record: `<git-dir>/merge-orig`, written by `record_tip` and read by `landed` in `@bin/lib.sh`.
- Drop record: `<git-dir>/merge-dropped`, the commits the agent skipped as already on the target; read by `landed`, removed with `merge-orig`.
- Moves log: `<git-common-dir>/wt-merge.moves`, one `<from> <to>` line per target move made under the lock; read by ship.sh's fence.
- Pending record: `<git-common-dir>/wt-merge.pending`, the target and the branch before `wt merge`; removed on every exit, so it outlives only a killed merge.sh.
- Exit codes: 0, 1, 2, 5; otherwise the code of `wt merge`.
- Events when `MERGE_EVENTS` is set: `lock-wait`, `lock-taken`, `index-lock-removed`, `ref-lock-removed`, `target-resynced`, `target-pulled`, `target-pushed`, `push-rejected`, `merge-done` with `rc`.

## Normative Behavior
1. WHEN merge.sh starts, it MUST take an exclusive `flock` on the lock file before any git write.
2. WHILE another process holds the lock, merge.sh MUST wait and print the holder named in the lock file.
3. WHEN the lock is taken, merge.sh MUST check `index.lock` in this worktree and in the target's checkout, the target's ref lock and `packed-refs.lock`.
4. WHEN the target's checkout index equals a recent target tree that is an ancestor of the target, merge.sh MUST sync that checkout.
5. WHEN the lock is taken, merge.sh MUST record the branch tip in `merge-orig` unless HEAD is already on the target.
6. WHEN `MERGE_PREPARE` is set, merge.sh MUST run it with `sh -c` under the lock before `wt merge`.
7. merge.sh MUST call `wt merge --yes --no-remove --no-squash --no-ff <target>` with its own arguments appended as flags.
8. WHEN `wt merge` exits 0, merge.sh MUST run `landed` and return its code.
9. WHEN `wt merge` exits 5, merge.sh MUST return 1.
10. WHEN `wt merge` exits with another non-zero code, merge.sh MUST return that code unchanged.
11. merge.sh MUST close fd 9 for every child (`9>&-`), so no child inherits the lock.
12. WHEN `MERGE_EVENTS` is set, merge.sh MUST append one JSON line per event listed in Surface.
13. WHEN this merge moved the target to a merge commit whose first parent is the target read before `wt merge` and whose second parent is this branch's tip, merge.sh MUST append `<old> <new>` to the moves log before it releases the lock (R8f).
14. WHEN the target moved to any other commit during this merge, merge.sh MUST NOT record that move (R8b).
15. WHEN `SHIP_AGENT_RUN` names this repository's git common dir, merge.sh MUST exit 2 before it takes the lock (R8c, R8d).
16. WHEN a commit reached the target between merge.sh reading it and the rebase, merge.sh MUST NOT record the move (R8e).
17. WHEN `MERGE_PUSH` names a remote, merge.sh MUST fetch that remote's target under the lock before `wt merge`.
18. WHEN the remote's target is ahead of the local target, merge.sh MUST move the local target and its checkout to it and record that move (R19b).
19. WHEN the local target is ahead only by recorded moves, merge.sh MUST push it before merging (R19e).
20. WHEN `MERGE_PUSH` is set and this merge moved the target, merge.sh MUST push the new target, also when `landed` returns 5 (R19h).
21. WHEN the push is rejected because the remote's target moved, merge.sh MUST put the target and its checkout back, record that move, and merge again on top, up to 5 tries (R19c).

## Constraints & Invariants
- Invariant: two merge.sh processes of one repository are never inside the rebase, hook and fast-forward section at once (`@lab/lock.sh` T1, T2; 0 overlaps, `@measurements/REPORT.md`).
- Invariant: the lock dies with the holder: a SIGKILL frees it; takeover p95 0.07 s (`@lab/lock.sh` T5, 5 reps, 2026-10-22).
- Invariant: exit 5 has one meaning: the branch is on the target and a recorded commit is missing (R1, R3, R4 in `@lab/recover.sh`).
- Constraint: `landed` matches a recorded commit on the target by author, author date and subject, by patch (`git cherry`), by content (applying it to the target changes nothing), or by its sha in `merge-dropped`.
- Constraint: the target is `MERGE_TARGET`, else `wt config state default-branch`; with neither, exit 2 before the lock (`@bin/lib.sh`).
- Constraint: `--no-squash` is fixed; a squash drops the commit messages that carry the task's intent.
- Constraint: `--no-ff` is fixed; every first-parent commit of the target is a tree the pre-merge hook tested, and a red commit inside a branch stays on the second parent (R20).
- Invariant: with `MERGE_PUSH`, merge.sh exits 0 only when the remote holds the merge (R19, R19c, R19f).
- Constraint: the target-checkout sync touches only an index equal to a recent ancestor target tree; a human's staged work stays (R2).
- Constraint: bash 3.2 compatible; perl provides `flock` and file times; git ≥ 2.40 (`merge-tree --merge-base`).

## Failure Behavior
1. IF `MERGE_PREPARE` exits non-zero, THEN merge.sh MUST print the command and exit 1 without calling `wt merge`.
2. IF an `index.lock`, the target's ref lock or `packed-refs.lock` is older than `MERGE_STALE_INDEX_LOCK` seconds, THEN merge.sh MUST remove it and continue (R5, R7).
3. IF such a lock is younger than that, THEN merge.sh MUST exit 1 and name the file.
4. IF the branch is on the target but a recorded commit is not, THEN merge.sh MUST exit 5 and print `git reset --hard <tip>` (R1).
5. IF the rebase stops on a conflict, THEN merge.sh MUST leave the rebase open in the worktree and return `wt merge`'s code.
6. IF a rebase drops a commit whose patch is already on the target, THEN `landed` MUST return 0 (R3).
7. IF a dropped commit applies cleanly to the target and changes nothing, THEN `landed` MUST return 0 (R6).
8. IF the agent named a dropped commit in `merge-dropped`, THEN `landed` MUST excuse that commit only (R6).
9. IF a `pre-merge` hook exits 5, THEN merge.sh MUST return 1 (R4).
10. IF a merge was SIGKILLed between moving the target and syncing its checkout, THEN the next merge.sh MUST finish that sync (R2).
11. IF applying a dropped commit to the target conflicts, THEN `landed` MUST count that commit as lost (R6c).
12. IF the local target has commits the remote's target lacks that no merge.sh recorded, THEN merge.sh MUST exit 2 and push nothing (R19d).
13. IF the fetch fails, THEN merge.sh MUST exit 1 before `wt merge`.
14. IF the remote refuses the push without moving its target, THEN merge.sh MUST put the target and its checkout back and exit 1 (R19f).
15. IF `merge-orig` is empty or names no commit, THEN `record_tip` and `landed` MUST treat it as absent (R12b).
16. IF `wt-merge.pending` names the target's first parent and its branch's tip is the target's second parent, THEN merge.sh MUST record that move (R19i).
17. IF the target is any other unrecorded merge commit, THEN merge.sh MUST NOT record it (R19k).

## Conformance
An implementation is conformant when it satisfies behaviors 1–21, holds the invariants, and follows failure rules 1–17. `@lab/recover.sh` (R1–R8, R6c, R8b–R8f, R12b, R19–R19k, R20, for `main`, `master` and `MERGE_TARGET=develop`) and `@lab/lock.sh` (T1–T6) are the executable checks; `@.config/wt.toml` runs them on every merge of this repository.

Given a rebase killed at its start and then continued with no commit picked,
When merge.sh runs again on that branch,
Then it exits 5 and prints the `git reset --hard` that restores the tip.