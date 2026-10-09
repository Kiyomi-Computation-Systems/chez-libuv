# #96: the exit's re-claim, split by an engine: mutation log

Branch `test/exit-reclaim-row`, built on main b539aff and moved onto v0.8.0's
ad3bb47 before #96's review, 2026-10-09. Guix container
(ADR-0020), x86_64, Chez 10.4.1, libuv 1.52.1.

## What was weak

`call-with-uv-loop`'s exit tears its loop down. When another call takes the
claim between two of the teardown's steps, the teardown is refused
`'loop-running`, and the exit must leave the loop to that call. #83's N3
makes the exit claim it again after any refusal:

```scheme
(when (and failure (not (claim-refusal? failure)) (loop-open? loop))
→
(when (and failure (loop-open? loop))
```

Once the other call ends, the loop is left claimed by this thread with no
run in it, and every verb refuses it for good. Until now only
test-loop-claim's exit race held this, and it catches N3 only when the
other thread's run ends in the instant between the refusal and the
re-claim. #91's log measured 5 of 5 races on macOS and 1 of 10 on an arm64
Linux mirror.

## Two things the issue's plan did not know

The issue proposed running the body in an engine, forging the claim to
another thread at one expiry with `set-loop-holder!`, and clearing it at a
later one. Two measurements changed the plan.

**1. An expiry inside the body tears the loop down at the suspension.**
Chez runs `dynamic-wind` exits when an engine suspends. ADR-0019 records
this, and docs/api.md tells users. So the first expiry has to come after
the escape, inside the exit itself; any earlier one runs the exit there and
then, where no later expiry can split it. With fuel 1 from the start, every
run raised `&uv-handle-closed` from the body's re-entry.

Where an engine's first expiry lands, by its first-slice fuel (probe, two
runs, identical):

| First slice (ticks) | Where the first expiry lands |
|---|---|
| 1–42 | before the escape |
| 43–46 | inside the callback, after the escape flag is set: the exit runs at the suspension |
| 47–48 | inside the exit, the claim still held |
| 49–53 | the gap after the teardown's first step gives the claim back |
| 54–71 | the drain's claim |
| 72 | a later gap |
| 73 on | none: the body takes about 72 ticks |

Chez counts ticks at procedure calls, not inside libuv. So each run starts
with a first slice that rises by one tick each time a run's first expiry
comes too early (`early`), and goes on one tick at a time after it. The
sweep found 47 in every run here.

**2. On a correct build, no expiry comes between the drain's refusal and
the exit's return.** With the forgery placed at tick 49, clears 1–4 land
before the drain's claim, so the teardown finishes. At clear 5 the run has
already ended, with the forgery still held. The issue's precondition, a
clear inside the exit after the refusal, can never hold on a correct build.
N3's re-claim brings expiries of its own ahead of its claim, so under N3
clear 5 lands between the refusal and the re-claim, and the re-claim
succeeds:

| Clear point | Correct build | N3 |
|---|---|---|
| 1–4 | `torn-down` | `torn-down` |
| 5 | `forgery-held` (the sweep ends: reached) | `claimed-by-this-thread` |
| 6 | — | `forgery-held` |

## The rows

`tests/test-loop-claim.sps`, after "call-with-uv-loop's exit refuses a loop
whose claim a close on another thread holds":

- **The main row** requires that no run left the loop claimed by this thread
  and that the sweep ended `reached`. `reached` means the last run ended with
  the forgery held and the loop open, so its drain was refused, and every
  clear point before it was tried.
- **The precondition** requires that the forgery came before the drain's
  claim: some runs' teardowns finished, and in the last run the body's
  timer is still `closing`. The drain is what finishes that close, so a
  timer still closing means the drain was refused. A forgery placed after
  the drain, in the gap before the close's claim, leaves it `closed`.
- A run counts as `forgery-held` only when the forged thread still holds
  the claim, and the clear releases only a claim that is still the
  forgery. A clear that finds anything else, or a final holder other than
  the forgery, is listed as wrong. A loop that will not tear down once
  taken back is listed too.

The engine is `exit-split-run`, bounded by `exit-split-resumes` per run and
`exit-split-cap` runs, and listed in test-sweep's engine census.

A run that escapes its callback, or is suspended inside it, strands that
`uv_run`'s frames on the main thread and one `jmp_buf` block (AGENTS.md). A
sweep is about 50 runs, and the main thread holds 16,000 escapes or more on
both platforms. test-loop-claim is in `MEMORY_ESCAPE_SUITES`.

## Evidence

Each run is the whole suite, run in the container with N3 as a copy of
`src/libuv/loop.sls` put first on `CHEZSCHEMELIBDIRS`.

| Build | Runs | Result |
|---|---|---|
| correct | 20 | 20 pass (and 20 again after the review) |
| N3 | 10 | the new row fails by name in **10 of 10**, every time `(((47 5 claimed-by-this-thread)) reached)` (and 10 of 10 again after the review) |
| steal: after a claim refusal the exit writes its own thread into the claim | 1 | the new row fails by name: `claimed-by-this-thread` from clear point 5 to the cap. The whole suite hangs on it further down, so these ran on a copy of the suite cut after the new rows |
| erase: after a claim refusal the exit clears the claim | 1 | the new row fails by name: `((47 5 forgery-erased)) ended-early`. The whole suite hangs too |

Under N3 the exit race failed too, in 10 of 10 here: `(80 stopped)`,
`(35 stopped)`, … `(131 stopped)`. On this x86_64 machine the race catches
N3 far more often than on #91's arm64 mirror. The engine split does not
depend on that.

Harness mutants, in copies of the suite:

| Mutant | Result |
|---|---|
| H1: the forgery is never cleared | the precondition fails by name, `(() 0 reached 47)`: no teardown finished |
| H3: the forgery placed only once the timer has closed, after the drain | the precondition fails by name, `((torn-down 0) (reached closed))` |
| H2: an early first expiry is not detected | both rows fail by name with `(sweep-raised … uv-loop-open? not-a-uv-loop)` |
| the engine not in test-sweep's census | test-sweep's census row fails by name |

## The review

`/code-review` (high) on the uncommitted branch raised nine findings, each
checked against the code before it was acted on.

1. **A run counted as `forgery-held` whoever held the claim.** Reproduced:
   the steal and erase mutants passed both new rows. Fixed.
2. **The clear released whatever claim it found.** Same mutants. Fixed.
3. **The precondition did not show the forgery came before the drain's
   claim.** A forgery in the later gap still left some teardowns
   finishing. Fixed with the timer's state; H3 fails it.
4. **A loop that failed its cleanup was not reported.** Fixed: listed as
   `(cleanup …)`.
5. **A re-claim with no expiry ahead of it would pass.** True, and not
   coverable here: an N3 that claimed again inside the step that was
   refused, or with no procedure call between the refusal and the claim,
   gives no expiry for a clear to land on. No such variant exists in the
   source today. The exit race still covers it, but only by chance.
   **Not covered.**
6. **The comments credited "1 of 10" to Linux as a whole.** It was #91's
   arm64 mirror. Corrected, with this machine's 10 of 10.
7. **test-sweep's census comment said every listed engine resumes once.**
   Widened.
8. **The run re-implements uv-sweep's capped resume loop.** The driver has
   no separate first slice: run-capped* resumes at one fuel until its last
   change. Adding one changes a shared pure library and its own rows, which
   is #103's work. Not done here; the give-up now names its cap as the
   driver's does.
9. **One branch of the sweep rebuilt `stop`'s answer by hand.** Fixed.

## Gates

In the container: `make test` (33 suites, all passed), `make check-purity`,
and `make HAVE_PKG=no test-memory MEMORY_TESTS=tests/test-loop-claim.sps`,
which passed with 21 escape blocks suppressed. After the review, on
ad3bb47: `make test`, `make check-purity`, and the Valgrind run (25 rows,
0 bytes definitely lost, 21 escape blocks suppressed) again.

**Not run on macOS.** The tick bands above are measured on Linux. The sweep
finds its own first slice, so a different count on macOS changes where it
starts, not what the row asks. One `make test` on a Mac, with N3 planted
once, would settle the issue's "both platforms".
