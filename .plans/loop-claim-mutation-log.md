# The loop's claim (#78): evidence and mutations

Issue #78, found reviewing #77: `uv-run` meant to refuse a loop another call
was running (`'loop-running`), but it read the mark and set it as two plain
steps, with the mode, the pointer, the deferred list and the owner in
between. `uv-loop-close!` and `uv-loop-teardown!` read the same mark the same
way. This log holds the reproduction, the design, the tests, and the
mutations that show each test fails by name.

macOS arm64, Chez 10.4.1 threaded, libuv 1.52.1 (Homebrew), base main
`41fdf4c` (#77). The box carried another session's CPU hogs from 19:16 to
19:46 (load average up to 455); the runs below say which ran under them.

## The reproduction

The issue's probe (two threads, 200,000 `uv-run 'nowait` each, on one loop
with 20 repeating 1 ms timers) on `41fdf4c`, three runs at load 5: two
raised `invalid memory reference` out of a thread's `uv-run`, and one ran
clean.

The issue left a same-thread version "plausible but untested": an engine
suspended between the check and the set. It is real. The new suite's split
sweep runs a `uv-run 'nowait` in an engine at fuel 1, 2, ..., and at the
first expiry closes the loop on the same thread. On `41fdf4c`, at fuel 8
and 9 the close was accepted, and the resumed run raised `invalid memory
reference`: it had read the pointer before the expiry, and ran the block
the close had freed. Tearing down instead of closing failed at the same
fuels.

## The design

`claim-loop!` in `(libuv private handles)`:

- The mark is a box per loop, taken by `box-cas!`. No lock: a lock every
  loop's thread shares would put every run of every loop behind it, and the
  registry's lock is held to table operations by rule 6. 16 B a loop.
- The take, the open check and the owner transfer are one `one-step`, so no
  engine of the claiming thread comes between them. The open check comes
  after the take, so a run that claims after a close finds the loop closed.
- A refused claim changes nothing: not the mark, not the owner.
- `memory-order-acquire` after the take, `memory-order-release` before the
  clear.
- A failed `box-cas!` is a refusal only when the mark is set; otherwise the
  take is retried (a compare-and-set may fail spuriously on some
  platforms).

`uv-run`, `uv-loop-close!` and `uv-loop-teardown!` each claim, and give the
claim back on every exit, raises included. A run and a close answer their
refusals (a callback's error, libuv's `EBUSY`) and raise them once the claim
is back; a teardown, whose raises come from deep in its work, gives the
claim back in a `guard` (`holding-claim`). A run and a teardown take the
loop over; a close does not. The pending callback error is taken while the
claim is held. `uv-run` keeps its unfenced first check of the mark only to
keep refusing `'loop-running` before an unknown mode.

## Cost

A scratch benchmark (1,000,000 runs; 100,000 make-and-close cycles), base and fix alternating, three runs each,
load 5:

| Call | Base | Fix |
|---|---|---|
| `uv-run 'nowait` on an empty loop | 80.9–81.8 ns, 16 B | 86.3–87.6 ns, 16 B |
| `make-uv-loop` + `uv-loop-close!` | 448 B, 5.5–5.6 µs | 464 B, 5.6 µs |
| `make-uv-loop` + `uv-loop-teardown!` | 946 B, 5.9–6.0 µs | 970 B, 5.9–6.3 µs |

The 16 B is the box. A first shape put `uv-loop-close!`'s work inside the
same `guard` as the teardown's: 858 B a close, +410 B. The close now answers
libuv's return code and raises after giving the claim back.

## The tests

`tests/test-loop-claim.sps`, 26 rows, 1.8 s at load 5 (32 s at load 450):

- **From another thread, while this thread runs the loop** (3 rows): each
  verb is refused `'loop-running`, and inside the run the loop is still
  claimed and still this thread's; after the run the claim is free.
- **A close refused `EBUSY` on another thread leaves the owner** (1), and a
  `uv-run` with an unknown mode on a running loop is refused `'loop-running`
  (1).
- **Every way out gives the claim back** (5): a run whose callback raised, a
  close refused `EBUSY`, a teardown that re-raises a close callback's
  error, a teardown that gives up at its drain bound (a close callback
  starts a timer the teardown never saw), a second close of a closed loop.
- **A teardown on another thread whose close callback escapes** leaves the
  loop claimed and owned by that thread (1).
- **Engine splits** (3 sweeps, each with a precondition row that the split
  landed both before the run's claim and during it): close, teardown, and
  another run whose callbacks raise, judged by the deferred errors the
  resumed run reports.
- **Races** (skipped under Valgrind): two threads run one loop with 20 timers
  (3 runs: every call runs or is refused, at most one callback at once, the
  claim free afterwards, and preconditions that each thread saw the other
  move and was refused at least once); one thread runs a loop while another
  tears it down, and while another closes it (200 loops each, with a
  precondition that some ender was refused first).

Every wait on another thread gives up at 10 s, so a build that hangs two
threads in `uv_run` fails rows by name: on `41fdf4c` a run of the suite
reported `(never-ended never-ended)` and skipped the races after it, naming
the stuck run.

## Against the base

The final suite against `41fdf4c`'s `src/` (a scratch copy), three runs at
load 4: 6, 9 and 11 rows failed by name. These failed in every run:

| Row | Failed with |
|---|---|
| uv-run split, close | fuel 8, 9: `accepted` then `invalid memory reference` |
| uv-run split, teardown | the same |
| two threads run one loop | `invalid memory reference` raised out of `uv-run` |
| ...the claim is free afterwards | follows from the raise, or `'loop-running` for good |
| teardown while another runs | `invalid memory reference` in the runner |

The others failed in some runs: "no two callbacks at once" (`2`), the close
race (both threads `never-ended`), and the preconditions of races skipped
after a stuck run, which name the stuck run as their evidence. One run under
load ~300 failed only the five above.

## Mutations

Each row copies the worktree's `src/` fresh into the scratchpad, applies one
exact replacement (the script aborts unless it matches once), and runs
`tests/test-loop-claim.sps` against the copy. Control: 0 failures.

| # | Mutation | Result |
|---|---|---|
| M1w | the claim always takes the mark (`(begin (set-box! mark #t) #t)`): the base's shape, refusals only from the unfenced first check | 13 FAIL: close and teardown from another thread, the close split sweep, every race row |
| M1t | non-atomic check-then-set inside the step (`(and (not (unbox mark)) (set-box! …))`) | 9 FAIL: every race row |
| M2 | a refused claim clears the mark | 11 FAIL, including all three "from another thread" rows (`not-running` inside the run) |
| M3 | a refused claim takes the owner | 2 FAIL: close and teardown from another thread (`owner-moved`) |
| M4 | the open check read before the take | **survived**, see below |
| M5 | `holding-claim` re-raises without giving the claim back | 1 FAIL: the drain-bound teardown row |
| M5c | `uv-loop-close!` raises libuv's refusal before giving the claim back | 2 FAIL: both `EBUSY` rows |
| M6 | teardown never gives the claim back | 3 FAIL: the teardown re-raise row, the teardown split sweep, the teardown race |
| M7 | `uv-run` raises the callback error before giving the claim back | 3 FAIL: the raising-callback row, the deferral split sweep and its precondition |
| M8 | a close takes the loop over | 1 FAIL: the `EBUSY`-on-another-thread row |
| M9 | a teardown does not take the loop over | 1 FAIL: the escaping-close-callback row (`owned-by-another`), once that row existed; it survived the first sweep |
| M10a | no acquire fence after the take | **survived**, see below |
| M10b | no release fence before the clear | **survived**, see below |
| M11 | the pending error taken after the claim is given back | **survived**, see below |
| M12 | no unfenced first check in `uv-run` | 1 FAIL: the unknown-mode row |
| M13 | a failed `box-cas!` is always a refusal | **survived**, see below |
| M14 | the deferred list reset before the claim, not in the claimed run | 1 FAIL: the deferral split sweep, once it existed; it survived the first sweep |

M9 and M14 survived the first sweep. The escaping-teardown row and the
deferral split sweep were written for them, and each fails by name now.
When the close stopped using the `guard` (see Cost), M5 lost the `EBUSY`
rows that had caught it, and the drain-bound row was written for it. The
table is the final sweep on the final code: 18 mutants, 13 caught by
name.

### Uncovered, and why

- **M4** (open check before the take). No expiry of the split sweeps landed
  between the read and the step: the read is the last call before
  `one-step` disables interrupts. Across threads the window is the few
  instructions between the read and the compare-and-set, and the close race
  did not reach it. The comment on
  `claim-loop!` states the order; nothing checks it.
- **M10a/M10b** (fences). No test here can observe a reordering: arm64's
  reorderings across a contended compare-and-set are not reproducible on
  demand. They are kept because the release/acquire pairing is what makes
  one thread's libuv state visible to the next holder.
- **M11** (pending error after release). No expiry of the deferral sweep
  landed between the release and the take, which are adjacent. Across
  threads, another run would have to claim, run and raise in a callback
  within those few instructions.
- **M13** (spurious failure). Whether `box-cas!` fails spuriously depends on
  the platform's code generation; no run here produced a refusal from an
  unset mark. The retry is defensive.
