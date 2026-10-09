# #110: the level-3 child's exit status, and its reaping: mutation log

Branch `fix/level-3-exit-status`, on main 0ac482c, 2026-10-09. Guix
container (ADR-0020), x86_64, Chez 10.4.1, libuv 1.52.1.

## What was weak

`level-3-run` (`tests/uv-level-3.sls`) starts its child with
`open-process-ports`, which gives a pid and nothing that waits on it.

- A child that died before printing anything was answered `(unreadable ""
  "")`, with nothing saying why: the `SIGABRT` of a Chez spawned with the
  wrong argv[0], or the `SIGSEGV` the level-3 children exist to contain.
- Nothing reaped a child, killed or finished. Each stayed a zombie until
  the suite exited.
- The end of both pipes was taken for the child's end. A child that closed
  them and kept running was answered at once, and left running.
- A datum was taken for success whatever the child did after printing it.

## The change

The runner waits through libc's `waitpid` with `WNOHANG`, polled every
10 ms. `make check-purity` poisons only the shim, so the suite stays pure,
and the kill still reaches Chez: the command still execs it.

- A child has finished when both pipes have ended **and** it has been
  reaped, by the same deadline. One not reaped by then is killed like a
  stalled one.
- Each report carries a status: `(exit code)`, `(signal number)`,
  `(not-reaped)` for a child not ended a second after its kill,
  `(wait-failed)` for a `waitpid` that refused, or `(wait-unavailable)`
  where libc did not load. `unreadable` and `killed-at-cap` gain it last,
  and `run-failed` second.
- A refused `waitpid` is not a child still running. With SIGCHLD ignored,
  for one, the system reaps each child itself and `waitpid` answers -1 with
  ECHILD; that is `(wait-failed)` at once, and a datum with it is
  `bad-exit`. An environment that hands the suite SIGCHLD ignored therefore
  fails every level-3 row, carrying the status, rather than passing on a
  status nobody read.
- libc is tried as `libc.so.6`, `libc.dylib` and `libc.so`. A load that
  fails leaves `waitpid` unbound rather than raising at import, which would
  have lost every row of test-addrinfo and test-process with it.
- A datum counts only from a child that exited 0. One that printed its
  datum and exited otherwise answers `(bad-exit out err status)`.
- Once a child is reaped its pid is free for reuse, so watch's handler
  kills only a child it has not reaped.

Chez's `system`, which the kill runs through, reaps only its own child: a
probe with two children, one killed through `system`, reaped both itself
afterwards.

## The rows

`tests/test-level-3.sps`, with new modes in
`tests/level-3-stand-in-child.sps`:

| Row | Mode | Expects |
|---|---|---|
| the zombie probe's precondition, before any run | the suite spawns `true` | `waitpid(-1)` answers its pid |
| stalled child (changed) | `stall` | `(killed-at-cap … (signal 9))` at the deadline |
| run-failed (changed) | `stall`, a deadline that is not a number | `(run-failed (signal 9))` |
| pipes closed, child running (new) | `hush` | `(killed-at-cap "" "hush child: closing\n" (signal 9))` at a 10 s deadline: its line shows it closed its pipes before the kill |
| garbage (changed) | `garbage` | `(unreadable … (exit 0))` |
| exit status (new) | `quiet-exit` | `(unreadable "" "" (exit 3))` |
| signal (new) | `abort` | `(unreadable "" "" (signal 6))` |
| datum, then a bad exit (new) | `datum-then-exit` | `(bad-exit "((level . 3))\n" "" (exit 5))` |
| SIGCHLD ignored: precondition (new) | the suite spawns `true` | `waitpid(pid)` answers -1: the system reaped it |
| SIGCHLD ignored (new) | `quiet-exit` | `(unreadable "" "" (wait-failed))` |
| no zombies, last | — | `waitpid(-1)` answers -1 |

The zombie probe is the suite's own FFI binding, not the runner's.

## Evidence

**Against main's runner** (the new rows, with main's
`tests/uv-level-3.sls`), each failed by name through its property:

| Row | Actual |
|---|---|
| stall | `(killed-at-cap "…" "…")`, no status |
| run-failed | `(run-failed "Exception in make-time: …")`, no status |
| hush (3 s deadline, before the review) | `((unreadable "" "") (took 0 seconds))` |
| garbage | `(unreadable "garbage\n" "garbage child: no datum\n")` |
| quiet-exit | `(unreadable "" "")` |
| abort | `(unreadable "" "")` |
| datum-then-exit | `((level . 3))` |
| no zombies | `(zombies (19 21 23 24 25 26) then -1)` |

**Runner mutants**, each a copy of `tests/uv-level-3.sls` first on
`CHEZSCHEMELIBDIRS`; correct build 11 of 11 (13 of 13 after the review).
M6 and M9 are not mutants: M6, the finished path's wait, cannot be broken
apart from the status it returns, which M1 and M2 cover; M9 is the
reaped-kill guard, under "Not covered".

| Mutant | Fails by name |
|---|---|
| M1: the exit code not shifted out of the status | quiet-exit `(exit 0)`, datum-then-exit `((level . 3))` |
| M2: a signal reported as an exit | stall, run-failed, hush, abort: each `(exit 9)` or `(exit 6)` |
| M3: a datum answered whatever the status | datum-then-exit `((level . 3))` |
| M4: run-failed's child not waited on | no zombies: `(zombies (80) then -1)` |
| M5: killed-at-cap's child not waited on | no zombies: `(zombies (95 100) then -1)` |
| M7: the wait ignores the deadline | hush: `((unreadable "" "" (exit 0)) (took 60 seconds))` |
| M8: a blocking wait (`WNOHANG` 0) | hush: the same |
| M10: run-failed waits without killing | run-failed: `(run-failed (exit 255))`, the child dying of its write to the closed pipe |

| A: a `waitpid` that refused taken for a child still running (`(<= r 0)`), from the review | the SIGCHLD row: `(killed-at-cap "" "" (not-reaped))`, after waiting out the deadline and killing a pid that was no longer its child. It passed all 11 rows before that row existed |
| U: no libc name loads | the suite runs all 13 rows; the 10 that need a status fail carrying `(wait-unavailable)`. Before the review, the load raised at import |

**Harness mutants:**
- The suite's probe answering -1 always fails the zombie precondition by
  name, `(got -1 for 6)`.
- `with-sigchld-ignored` leaving SIGCHLD's action alone fails the SIGCHLD
  precondition by name, `(waitpid-answered 18 for 18)`, and the row after
  it with `(unreadable "" "" (exit 3))`.

## Not covered

- **A kill after the child was reaped.** watch's handler skips the kill
  once the child is reaped, since its pid may be reused. Reaching it needs
  a raise after the reap, from closing a pipe or decoding the output, which
  no row can provoke. Removing the check fails nothing.
- **`(not-reaped)`.** A child not ended a second after `SIGKILL` cannot be
  made here; mutant C, answering `(wait-failed)` in its place, passes all
  13 rows.
- **The import's own failure.** Mutant U shows the rows fail by name, but
  no row can show the import does not raise where no platform here lacks
  libc.
- **The core-dump bit.** The signal is the status's low 7 bits, leaving out
  `0x80`, which is set when a core is written. The container writes no
  cores, so the abort row cannot see a mask of `0xff`.

## Also found

`tests/test-loop.sps`'s stranded-exit section runs its child with a runner
of its own. It has no deadline, reads stderr only after stdout has ended
(#88), and never reaps the child. Not changed here: #113 changes that suite.

## The review

An adversarial review on Opus (read-only) found no defect in the runner,
and four gaps, each checked before it was acted on:

1. **Two decisions no row held: a refused `waitpid` and `(not-reaped)`.**
   Reproduced: mutants A and C passed all 11 rows. A is now held by the
   SIGCHLD rows; C is under "Not covered".
2. **A failed libc load raised at import**, losing every row of the suites
   that import the runner. Fixed: `(wait-unavailable)`.
3. **The hush row had no precondition that the child closed its pipes
   before the kill.** Under load, a child killed before closing them would
   pass a runner that stops at their end. Fixed: the child's line, and the
   stall row's 10 s.
4. **SIGCHLD ignored in the environment turns every datum into
   `bad-exit`.** Kept on purpose, and recorded under "The change".

It also confirmed that vendored libuv reaps only its own pids
(`vendor/libuv/src/unix/process.c`), never `waitpid(-1)`, so libuv and the
runner cannot take each other's children.

## Gates

In the container: `make test` (all suites passed), `make check-purity`, and
`make HAVE_PKG=no test-memory MEMORY_TESTS="tests/test-level-3.sps
tests/test-addrinfo.sps"` (0 bytes definitely lost, nothing suppressed).
