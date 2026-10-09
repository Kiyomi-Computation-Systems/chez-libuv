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
Baseline: 4 passes, 6 s.

| # | Mutation | Result |
|---|---|---|
| M1 | stderr read only once stdout is done | **killed by name**: flood `(killed-at-cap "" "")`, stall's err `""` |
| M2 | finish at stdout's end alone | **killed by name**: garbage `(unreadable "garbage\n" "")` |
| M3 | `killed-at-cap` carries no output | **killed by name**: stall `(killed-at-cap within-the-deadline)` |
| M4 | read a ready pipe to its end (`get-bytevector-all`) | **killed by name**: stall `(took 60 seconds)` |
| M5 | read without asking readiness | **hangs**: killed by the 150 s cap, no row named |
| M6 | chunks joined newest first | **killed by name**: stall `" (objects((level . 3)"` |
| M7 | stdout never marked done | **killed by name**: flood and garbage `killed-at-cap` |
| M8 | stderr never marked done | **killed by name**: flood and garbage `killed-at-cap` |
| M9 | sleep only after a pass that read something | **killed by name**: `(spent 4981 ms)` |
| M10 | no deadline | **killed by name**: stall `(took 60 seconds)` |
| M11 | the default deadline 1 s instead of 60 | survives |

- **M5** deadlocks. The runner blocks reading stdout while the flood child
  blocks writing a full stderr pipe, and nothing in the suite's process
  runs until one of them gives way. No row can name a blocked read; make's
  `SUITE_TIMEOUT` reports it as `HUNG`.
- **M9** busy-waits. It answers correctly, so it was caught only once a row
  looked at the runner's CPU time across the stalled child's 5 s wait. A
  correct runner spent 13, 19 and 13 ms in three runs, M9 4,981 and
  4,982 ms. The row's bound is 1,000 ms.
- **M11** is a value, not a decision. A row on it would wait out the
  60 s. The consumers' children finish in under a second, so 1 s passed
  here; a slower machine compiling the level-3 libraries would kill them.
  Not covered.

## Harness mutants

Each weakens the stand-in, and the suite runs against the correct runner
and against the source mutant the weakened piece is there to catch.

| Weakened stand-in | Correct runner | Mutant |
|---|---|---|
| `stall` writes its half datum in one piece | passes | M6 **survives** |
| `garbage` does not close fd 1 | passes | M2 **survives** |

So the split write and the early close are each what catches their mutant.

## Gates

In the container: `make test` (33 suites, all passed; test-addrinfo's
and test-process's level-3 rows ran and passed on the new runner) and
`make check-purity` (`purity holds: tests/test-level-3.sps`).
