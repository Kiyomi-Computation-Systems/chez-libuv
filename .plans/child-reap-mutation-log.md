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
  wait. It sets `collect-request-handler` to `void` and puts the old
  handler back with `dynamic-wind`. The handler is global
  (`s/7.ss:1299`), so this defers collections on every thread. A request
  that arrives meanwhile is dropped (`$collect-request-pending` is
  cleared), and the next trip makes another one.
- A failed wait now says why:
  - `(wait-failed ECHILD)`: errno's name, for ECHILD, EINTR and EINVAL
    (the same numbers on Linux and macOS), or else the number. It is `#f`
    where errno cannot be read.
  - `(wait-raised text)` for a raise inside the wait.
  - errno is read through `__errno_location` (glibc) or `__error` (macOS)
    straight after `waitpid`, with interrupts disabled between the two.
- The stand-in child gains `outlived`. It prints its datum and exits 0 at
  once, leaving its pipes to a background `sleep 1`.
- test-level-3 gains three rows and changes one:
  - **precondition:** a collection reaps an ended child of
    `open-process-ports` by itself. It collects every generation, see
    below;
  - **outlived:** with collections forced every 256 B, a child that ends
    while the runner still polls answers its datum;
  - **handler:** `child-run` puts back the `collect-request-handler` it
    found, a procedure of the suite's own;
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
runs a suite. Baseline in the copy: test-level-3, 19 passes.

| Mutant | Row that failed, by name | Actual |
|---|---|---|
| M1 no deferral: the handler is set to what it already was | "a child that ends while the runner still polls answers its datum: no collection takes its status" (10 runs in 10) | `(bad-exit "((outlived . #t))\n" "" (wait-failed ECHILD))` |
| M2 errno dropped | "a child the system reaps first answers wait-failed with ECHILD, not killed-at-cap" | `(unreadable "" "" (wait-failed #f))` |
| M3 the handler is not put back | "child-run puts back the collect-request-handler it found" | `(left #<procedure void>)` |

Nothing else failed under any of them. On main's runner, before the fix,
the outlived row failed the same way as M1, with `(wait-failed)` and no
errno.

### Uncovered

- **M4: deferral begun after the spawn**, around the watch only. All 19
  rows passed. The window between `open-process-ports` recording the child
  and the deferral starting is a few instructions. A child would have to
  end in it, and a collection run, for anything to show. No row can make
  that happen, so the deferral wrapping the spawn is held only by reading
  the code.
- **M5: the raise's text dropped** from `(wait-raised text)`. All 19 rows
  passed. Nothing a row can arrange makes `waitpid`'s call or the status
  decoding raise.

## Gates

- `make test`: every suite passes.
- `make check-purity`: test-level-3 still loads no native code.
- `make HAVE_PKG=no test-memory MEMORY_TESTS=tests/test-loop.sps`
  (Valgrind), since the stranded child runs through `child-run`: 213
  passes, nothing definitely lost, 1,200 B in 6 blocks suppressed, the
  same as before.
