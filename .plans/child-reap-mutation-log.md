# #128: a collection took the child's status: mutation log

Branch `fix/child-reap-128`, on main 73f5a64, 2026-10-10. Guix container
(ADR-0020), x86_64, Chez 10.4.1.

## What failed

On CI, test-level-3's flood row answered
`(bad-exit "((stderr-bytes . 1048576))\n" … (wait-failed))` once, on a
correct build. The child had run correctly; only the runner's wait failed.
`try-reap` answered `(wait-failed)` both for `waitpid` refusing and for a
raise, and dropped the errno, so the log could not say which.

## Cause

Chez reaps the children it starts. `s_process` (`c/prim5.c:949`), behind
`open-process-ports` and `process`, records each child's pid
(`S_register_child_process`). Each collection then calls `waitpid(pid,
WNOHANG)` on the recorded pids in the generations it collects, and keeps
no status (`c/gc.c:1640-1660`). A collection after the child ended and
before `try-reap` left the runner's `waitpid` with `ECHILD`. The flood
row allocates 1 MiB while it drains, so it is the row most likely to
collect at that moment.

### Reproduced before the fix

`.plans/child-reap-probe.sps` runs the stand-in's `quiet-exit` and
`flood` children through `child-run` and counts each answer's shape.
`collect-trip-bytes` comes from its argument.

| Runner | trip bytes | flood: datum | flood: `(wait-failed)` |
|---|---|---|---|
| main's | 20 | 19 | 1 |
| main's | 4096 | 18 | 2 |
| fixed | 64 | 40 | 0 |
| fixed | 4096 | 40 | 0 |

`quiet-exit` answered `(unreadable … (exit 3))` every time on both: it
allocates almost nothing after the child ends.

The issue suggested looping the row under CPU load and a loopback flood
until it failed again. The cause was found in Chez's source instead, and
the outlived row below now reproduces the race deterministically, so that
loop was not run.

## The change

- `child-run` defers collections from before the spawn to after the last
  wait. It sets `collect-request-handler` to `void`, and puts back the
  handler the first run found when the last run on any thread ends: a
  count of runs under a lock, taken with interrupts disabled. The handler
  is global (`s/7.ss:1299`), so this defers collections on every thread.
  A request that arrives meanwhile is dropped (`$collect-request-pending`
  is cleared). While the bytes allocated since the last collection stay
  over the trip, every new allocation segment requests again
  (`c/alloc.c:209`), so `void` is called over and over during a run.
- A failed wait now says why:
  - `(wait-failed ECHILD)`: errno's name for ECHILD (10 on Linux and on
    macOS), or else the number. It is `#f` where errno cannot be read.
  - `(wait-raised text)` for a raise inside the wait.
  - errno is read through `__errno_location` (glibc) or `__error` (macOS)
    straight after `waitpid`, with interrupts disabled between the two.
- The stand-in child gains `outlived`. It prints its datum and exits 0 at
  once, leaving its pipes to a background `sleep 1`.
- test-level-3 turns collections off for the whole suite. It gains four
  rows, run before every other run, and changes one:
  - **precondition:** a collection reaps an ended child of
    `open-process-ports` by itself: `waitpid` then refuses with ECHILD. It
    collects every generation, see below;
  - **outlived:** with collections on and forced every 256 B, a child that
    ends while the runner still polls answers its datum;
  - **handler:** `child-run` puts back the `collect-request-handler` it
    found, a procedure of the suite's own;
  - **overlap:** two runs on two threads, the first to begin the first to
    end, each keep their status, and the handler found is back after both;
  - **changed:** the SIGCHLD-ignored row now expects
    `(wait-failed ECHILD)`.
- AGENTS.md gains the trap.

### The precondition flaked first

Collecting with a bare `(collect)`, the precondition failed 1 run in 3
(`(waitpid-answered 70 for 70)`): the collector had not reaped the child.
The pid list is per generation and moves up with the child. A collection
while `true` still ran had promoted its entry, and a bare `(collect)`
usually collects only generation 0. With `(collect
(collect-maximum-generation))`, 10 runs in 10 passed
(`.plans/precondition-loop.sh`). The runner is unaffected: it waits by
pid, not through the collector.

## Mutants

Each was made in a copy of the worktree outside the repo
(`$SCRATCH/m128`, by the guix-env recipe) and run the way `make test`
runs a suite. Baseline in the copy: test-level-3, 20 passes (19 before
the review).

| Mutant | Rows that failed, by name | Actual |
|---|---|---|
| M1 no deferral: the handler is set to the one it already was | outlived (10 runs in 10 before the review); overlap | `(bad-exit "((outlived . #t))\n" "" (wait-failed ECHILD))`; the same for both overlapping runs |
| M2 errno dropped | "a child the system reaps first answers wait-failed with ECHILD, not killed-at-cap" | `(unreadable "" "" (wait-failed #f))` |
| M3 the handler is not put back | handler; overlap | `(left #<procedure void>)` |
| M6 each run saves and restores the handler itself (the PR's first version) | overlap, 5 runs in 5 | `(((outlived . #t)) (bad-exit … (wait-failed ECHILD)) (left #<procedure void>))`: the first run's end turned collections on under the second, and the second's end left them off |
| Z the run-failed child reported `(signal 9)` without a wait | "no child is left unreaped" | `(zombies (26) then -1)` |
| Z with the suite collecting again | nothing: 20 passes | the collector reaped the zombie before the last row looked |

Nothing else failed under any of them. Z and Z-with-collections are the
review's point: before the suite turned collections off, the #110 zombie
row passed a runner that never waited. On main's runner, before the fix,
the outlived row failed the same way as M1, with `(wait-failed)` and no
errno.

The correct build passed all 20 rows 10 runs in 10.

### Uncovered

- **M4: deferral begun after the spawn**, around the watch only. All 20
  rows passed. The window between `open-process-ports` recording the child
  and the deferral starting is a few instructions. A child would have to
  end in it, and a collection run, for anything to show. No row can make
  that happen, so the deferral wrapping the spawn is held only by reading
  the code.
- **M5: the raise's text dropped** from `(wait-raised text)`. All 20 rows
  passed. Nothing a row can arrange makes `waitpid`'s call or the status
  decoding raise.
- **`with-interrupts-disabled` in `wait-once`**, and the lock's: nothing a
  row can arrange runs a handler between `waitpid` and the errno read, or
  stops a thread holding the lock.
- **`__error`**, macOS's errno: Linux never takes that branch. On macOS
  the SIGCHLD-ignored row reads errno only through it, so a broken
  fallback fails that row there, as M2 does here. Not run on macOS for
  this PR.
- **A dropped engine inside a run** leaves collections off for good. No
  suite runs `child-run` inside an engine. The runner's comment says it
  is not for engines.
- **The outlived child's orphan `sleep 1`** is reparented to the nearest
  subreaper, or PID 1. A suite run as PID 1 or under a subreaper would
  count it in the zombie row. Neither `make test` nor the Guix container
  runs it that way.

## Code review (PR #129)

Ten findings, all checked against the code and Chez's source:

| Finding | Outcome |
|---|---|
| Saving and restoring a global handler breaks when runs on two threads overlap out of order | Fixed: a count of runs under a lock. The overlap row and M6 hold it |
| The AGENTS.md entry claimed `uv-spawn!` children are safe; a pid the runner reaped stays on Chez's list until a collection, and a child that reuses it can lose its status | Reworded: the window needs pid wrap-around, and nothing holds it |
| Collections clear zombies, so the #110 zombie row passed a runner that never waited | Fixed: the suite turns collections off, and the collecting rows run first. Z holds it |
| The zombie probe's own precondition could lose its child to a collection | Fixed by the same suite-wide deferral |
| The probe counted `spawn-failed` as a datum | Fixed: only an alist is a datum. With `CHEZ_LIBUV_TEST_CHEZ` unset it answers `spawn-failed` |
| EINTR and EINVAL arms, `__error`, `with-interrupts-disabled` had no mutant and no "uncovered" entry | The two arms are gone; the rest are listed above |
| Deferring collections is a workaround: spawn outside Chez's registry (`posix_spawn`) instead | Not taken: the user chose to harden the deferral. None of the three suites that use the runner collects while a child runs |
| The precondition took any -1 for the collector's reap | Fixed: it must be ECHILD |
| Two hand-written `parameterize`s | The suite's became `parameterize`. The runner's is the counted deferral now |
| The orphan `sleep 1` | Listed above |

The re-request after a dropped one is per allocation segment, not per
trip, as the review also noted: corrected above.

## Gates

- `make test`: every suite passes.
- `make check-purity`: test-level-3 still loads no native code.
- `make HAVE_PKG=no test-memory MEMORY_TESTS=tests/test-loop.sps`
  (Valgrind), since the stranded child runs through `child-run`: 213
  passes, nothing definitely lost, 1,200 B in 6 blocks suppressed, the
  same as before.
