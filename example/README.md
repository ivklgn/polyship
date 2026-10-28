# Example

Three agents finish their tasks at the same moment. polyship lands them one at a time.

```bash
example/demo.sh
```

It takes about 15 seconds. You don't need an agent or an API key: the three sessions are scripted, and the review
step is off. Everything runs in a new directory under `/tmp`. You need `wt`, git and perl.

## What you see

```text
== three sessions run scripts/ship.sh at the same time
[greet] ship: tests before the queue
[greet] ship: merge (round 1)
[greet] ship: greet is on main
[greet] exit 0
[bye] ship: tests before the queue
[bye] ship: merge (round 1)
[bye] ship: bye is on main
[bye] exit 0
[help] ship: tests before the queue
[help] ship: merge (round 1)
[help] ship: help is on main
[help] exit 0

== main: one merge commit per task, each one a tested tree
*   Merge branch 'help' into main
|\
| * feat: help command
|/
*   Merge branch 'bye' into main
|\
| * feat: bye command
|/
*   Merge branch 'greet' into main
|\
| * feat: greet command
|/
* chore: the app, with polyship in scripts/
```

All three branches started from the same commit. Each one waited for the lock, was rebased onto the merges
before it, and passed the tests again before it landed.

## What a project adds

The demo builds the same three things you add to a real project.

`.config/wt.toml`: how to prepare a worktree and how to test it. The `pre-merge` command is the gate.

```toml
[post-start]
deps = "npm ci"

[pre-merge]
test = "npm test"
```

`scripts/`: `ship.sh`, `merge.sh` and `lib.sh`, copied by `install.sh` and committed.

`CLAUDE.md` or `AGENTS.md`: tells each agent to end its task with `scripts/ship.sh` (see the main README).

## With real agents

With a real agent, `ship.sh` does two more things:

- **Review.** Before the tests, an agent reviews the branch and fixes what it finds.
- **Conflicts.** When the rebase stops on a conflict, an agent resolves it and the branch goes back to the queue.
  If the conflict is a product choice, the agent stops and asks you (exit 3).
