# Marathon Mode - fresh-context outer loop

One long session degrades: context rots, compaction lurks, hour-three output is
worse than hour-one output. Marathon mode replaces the marathon session with N
fresh sessions iterating against a persistent state file. The state file is the
ONLY memory; every iteration starts clean and picks up exactly where the last
one stopped. Compaction stops being a threat by construction.

**When to arm it:** estimated wall-clock over ~90 minutes, overnight, or a handoff to another
machine, or `--marathon` passed. The controller arms it at the end of Plan
(after Checkpoint 1): write the state file, then either keep iterating
in-session against it (cheap insurance) or hand the loop to the driver (full
fresh-context isolation).

## State file

Location: `.superpowers/sdd/marathon-<slug>/state.md` (project root for code,
workspace root otherwise). Template, exact section names:

```
# Marathon State: <slug>
STATUS: running
GOAL: <one line>
ACCEPTANCE:
- [ ] <criterion> (CHECK: <command or observable evidence>)
DONE LOG:
- <ISO timestamp>: <increment that shipped>
NEXT STEP: <one concrete increment, small enough for one session>
GOTCHAS:
- <constraint learned the hard way; do not relearn it>
DECISIONS:
- <what was decided + why; do not re-litigate>
BLOCKERS:
```

Rules: `STATUS` is only ever `running | done | blocked`, lives on exactly ONE
line, and is EDITED IN PLACE, never appended as a second line (the driver reads
the last `STATUS:` line as a safety net, but append-drift is a contract
violation). An ACCEPTANCE box gets checked only with the evidence its CHECK
names, never on optimism. Timestamps come from `date`. The driver also exports
the state path as `$MARATHON_STATE`; when the prompt and the env var disagree
(path mangling, spaces), the env var is canonical.

## Iteration contract

Every `--resume-state` session does exactly this:

1. Read the state file. GOTCHAS and DECISIONS are settled; re-deriving them is
   the failure mode the file exists to prevent.
2. Execute ONE increment: the NEXT STEP. If it turns out too big for one
   session, split it and do the first piece.
3. Update the file: append the DONE LOG line, check any ACCEPTANCE boxes you
   now have evidence for, write the new NEXT STEP, record new GOTCHAS and
   DECISIONS.
4. All ACCEPTANCE boxes checked: run the fresh verifier
   (`references/quality-gates.md`). Verifier passes, set `STATUS: done`.
5. Stuck per the watchdog ladder below: record the dead approach in GOTCHAS.
   Ladder exhausted, set `STATUS: blocked` and write the ask into BLOCKERS.
6. End the session. Never start a second increment; "while I'm here" is how the
   state file drifts from reality.

## Watchdog ladder

Stuck signals: the same test failing on the 3rd attempt, the same error
signature twice, or an increment past ~30 minutes / ~60k tokens with nothing
state-worthy to show.

Escalation, in order:
1. `superpowers:systematic-debugging` on the real failure, once.
2. Abandon the approach: write it into GOTCHAS with why it failed, design a
   different attack, make that the NEXT STEP.
3. `STATUS: blocked` with a crisp BLOCKERS ask (what is needed, from whom).

Repeating rung 1 three times IS the definition of wedged; that urge means move
to rung 2. The driver adds a mechanical backstop: iterations that leave the
state file byte-identical count toward `--stall-limit`, then the loop stops and
notifies instead of burning tokens in place.

## Driver

`references/marathon/run.sh` runs the loop headless, one fresh `claude -p`
session per iteration:

```bash
~/.claude/skills/autonomous/references/marathon/run.sh \
  --state <path>/state.md --cwd <project> [--max-iter 12] [--stall-limit 2]
```

Exit codes: 0 done, 2 stalled, 3 blocked, 4 max-iterations, 64 usage/config
error (bad flags, missing state file, unreachable `--cwd`). It logs to
`marathon.log` next to the state file and notifies via `$HARNESS_NOTIFY_CMD`
(best-effort, never blocks, skipped when unset) plus a local macOS banner
(osascript, same best-effort rule, skipped off macOS) so a stopped loop is
visible on the machine itself even if the out-of-band channel fails.
`--iter-timeout N` guards hung sessions when coreutils `gtimeout` is installed.
Tests: `test-driver.sh` (fake binaries, no tokens).

Second-machine handoff: the driver works headless on any box that can run the
CLI non-interactively (it needs an auth token in the environment). Checkpoint 2
still fires when the loop ends, whichever machine ran it.
