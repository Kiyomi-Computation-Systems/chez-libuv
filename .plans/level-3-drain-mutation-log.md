# The level-3 runner's drain and deadline: mutation log

Evidence for #88. `level-3-run` in `tests/uv-level-3.sls` runs
test-addrinfo's and test-process's children at `--optimize-level 3`
under a deadline. It had two gaps. Neither had been seen to fail.

1. It read stderr only once stdout was ready. A child that wrote more
   than a pipe holds to stderr before its datum blocked on the full pipe,
   and was killed at the deadline as `killed-at-cap`. The stderr that
   explained it was lost.
2. Once stdout was ready, the read had no deadline. `get-string-all` waits
   for the end, so a child that printed part of a datum and then hung held
   the suite until make's `SUITE_TIMEOUT`, with no row naming the child.

## The change

- The runner reads both pipes as binary ports, taking one ready chunk from
  each on every pass. It finishes when both pipes have ended, or kills the
  child at the deadline. It sleeps 10 ms on a pass that read nothing.
- A killed child's report is `(killed-at-cap out err)`, carrying what it
  printed, where it was the bare symbol. `level-3-entry` already returns
  any report that is not an alist whole inside `(no-entry …)`. Neither
  consumer compared against the bare symbol.
- The deadline is an optional fourth argument, defaulting to
  `level-3-deadline-seconds` (60), so a row can use a short one.

The review of #108 (below) added three more:

- After the kill, the runner drains both pipes for up to a second more,
  for what the child wrote since the last pass and what the pipes still
  hold.
- Only the spawn answers `(spawn-failed text)`. A raise once the child is
  running kills it, closes both pipes, and answers `(run-failed text)`.
  Before, the whole run was under the spawn's `guard`, so such a raise
  was reported as a failed spawn and left the child running.
- `level-3-run`'s second name, `run-child`, is gone.

The rows are in a new pure suite, `tests/test-level-3.sps` (in
`PURE_TESTS`). It runs `tests/level-3-stand-in-child.sps`, which
misbehaves in three ways chosen by its argument:

| Mode | What it does |
|---|---|
| `flood` | writes 1 MiB to stderr, then its datum |
| `stall` | writes a line to stderr, then half a datum in two pieces 100 ms apart, then sleeps 60 s |
| `garbage` | prints a non-datum, closes fd 1, and 500 ms later writes a line to stderr and exits |

Closing Chez's output port does not close fd 1: probed with a pipe into
`cat`, stdout ended only when the child exited. So `garbage` calls libc's
`close` through the FFI. That loads `libc.so.6`, or `libc.dylib` when that
fails. Only the Linux branch has run (Guix container, x86_64); CI runs no
macOS job.

Platform for everything below: Guix container (ADR-0020), x86_64, Chez
10.4.1, 2026-10-09.

## On main

Main's runner with only the deadline argument added, before the drain,
run with `make test TESTS=tests/test-level-3.sps`:

```
FAIL a child that writes 1 MiB to stderr before its datum answers the datum
  actual: killed-at-cap
FAIL a child that prints half a datum and stalls is killed at the deadline, carrying what it printed
  actual: ((unreadable "((level . 3) (objects" "stall child: stalling\n") (took 60 seconds))
# of expected passes      1
# of unexpected failures  2
```

The suite took 83 s: 20 s for the flood child's deadline, and 60 s for the
stalled child's sleep, which main's runner waited out. (The stand-in then
wrote its half datum in one piece; the split came with the M6 row below.)

## Source mutants

Each is a copy of `tests/uv-level-3.sls` put first on
`CHEZSCHEMELIBDIRS`, the suite run in the container under `timeout 150`.
Baseline: 5 passes, 11 s. The stall row's deadline is 10 s.

| # | Mutation | Result |
|---|---|---|
| M1 | stderr read only once stdout is done | **killed by name**: flood `killed-at-cap`, its stdout `""` |
| M2 | finish at stdout's end alone | **killed by name**: garbage `(unreadable "garbage\n" "")` |
| M3 | `killed-at-cap` carries no output | **killed by name**: stall `(killed-at-cap at-the-deadline)` |
| M4 | read a ready pipe to its end (`get-bytevector-all`) | **killed by name**: stall `(took 60 seconds)` |
| M5 | read without asking readiness | **hangs**: killed by the 150 s cap, no row named |
| M6 | chunks joined newest first | **killed by name**: stall `" (objects((level . 3)"` |
| M7 | stdout never marked done | **killed by name**: flood and garbage `killed-at-cap`; CPU `(spent 1028 ms)` |
| M8 | stderr never marked done | **killed by name**: flood and garbage `killed-at-cap`; CPU `(spent 1016 ms)` |
| M9 | sleep only after a pass that read something | **killed by name**: `(spent 9979 ms)` |
| M10 | no deadline | **killed by name**: stall `(took 60 seconds)` |
| M11 | the default deadline 1 s instead of 60 | survives |
| R1 | kill at a fifth of the given deadline | **killed by name**: stall `(took 2 seconds)`, CPU `(wait-ended-after 2 seconds)` |
| R2 | a raise while running answered as `spawn-failed` | **killed by name**: `spawn-failed` |
| R3 | a raise while running does not kill the child | survives |
| R4 | no drain after the kill | survives |

- **M5** deadlocks. The runner blocks reading stdout while the flood child
  blocks writing a full stderr pipe, and nothing in the suite's process
  runs until one of them gives way. No row can name a blocked read; make's
  `SUITE_TIMEOUT` reports it as `HUNG`.
- **M7 and M8** also fail the CPU row. A pipe at its end is always ready,
  so a pipe never marked done is read on every pass and the runner never
  sleeps, here through the second of draining after the kill.
- **M9** busy-waits. It answers correctly, so it is caught only by a row
  on the runner's CPU time across the stalled child's wait. In a 5 s wait,
  a correct runner spent 13, 19 and 13 ms in three runs, M9 4,981 and
  4,982 ms. The row's bound is 1,000 ms, and it requires the wait to have
  lasted the deadline, or any runner that answered early would pass.
- **M11** is a value, not a decision. A row on it would wait out the
  60 s. The consumers' children finish in under a second, so 1 s passed
  here; a slower machine compiling the level-3 libraries would kill them.
  Not covered.
- **R1** passed every row before the review: the stall row checked only
  that the runner answered within the deadline plus its slack, and a
  runner that kills early still carries what the child printed. The row
  now requires the answer no sooner than the deadline.
- **R2's row** faults the wait with a deadline that is not a number, the
  one raise after the spawn that the suite can cause on demand.
- **R3** is not covered. The suite does not know the child's pid, so it
  cannot see that the child outlived its report.
- **R4** is not covered. A correct runner reads both pipes on every pass,
  so at the kill they hold only what the child wrote in the last 10 ms or
  so, and nothing tells a row what that was. The drain shows in other
  mutants' evidence: under M1, the flood row's report now carries the
  64 KiB the stderr pipe held at the kill, where without the drain it
  carried nothing.

## Harness mutants

Each weakens the stand-in, and the suite runs against the correct runner
and against the source mutant the weakened piece is there to catch.

| Weakened stand-in | Correct runner | Mutant |
|---|---|---|
| `stall` writes its half datum in one piece | passes | M6 **survives** |
| `garbage` does not close fd 1 | passes | M2 **survives** |

So the split write and the early close are each what catches their mutant.
Rerun against the suite as the review left it, with the same results.

## The review

`/code-review` (high) on f642313 raised eight findings, and each was
checked against the code before being acted on:

1. **No row held the runner to the given deadline as a minimum.**
   Reproduced: R1 passed all four rows. Fixed (the stall row's lower
   bound).
2. **The CPU row passed for any runner that answered early.** Fixed: it
   requires the wait to have lasted.
3. **The kill threw away what the pipes still held.** Fixed (the drain
   after the kill); not covered by a row (R4).
4. **The spawn's `guard` covered the whole run.** Fixed (`run-failed`,
   R2); the kill in it is not covered (R3).
5. **The stall row's 5 s deadline counted Chez's startup under load.**
   The deadline is now 10 s.
6. **No report carries the child's exit status, and the child stays a
   zombie until the suite exits.** Real, and older than #88:
   `open-process-ports` gives no way to wait on the child. Left for an
   issue of its own.
7. **The stand-in's `libc.dylib` branch has never run.** Stated above and
   in the PR; it needs one `make test` on a Mac.
8. **`run-child` was a second name for `level-3-run`.** Removed.

## Gates

After the review, in the container: `make test` (33 suites, all passed; test-addrinfo's
and test-process's level-3 rows ran and passed on the new runner) and
`make check-purity` (`purity holds: tests/test-level-3.sps`).
