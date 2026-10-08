# The loop's claim (#78): evidence and mutations

Issue #78, found reviewing #77: `uv-run` meant to refuse a loop another call
was running (`'loop-running`), but it read the mark and set it as two plain
steps, with the mode, the pointer, the deferred list and the owner in
between. `uv-loop-close!` and `uv-loop-teardown!` read the same mark the same
way. This log holds the reproduction, the design, what the review of the
first version found and how the design changed, the tests, and the mutations
that show each test fails by name.

macOS arm64, Chez 10.4.1 threaded, libuv 1.52.1 (Homebrew), base main
`41fdf4c` (#77). Times are at load average 4–6 unless a section says
otherwise.

## The reproduction

The issue's probe (two threads, 200,000 `uv-run 'nowait` each, on one loop
with 20 repeating 1 ms timers) on `41fdf4c`, three runs: two raised
`invalid memory reference` out of a thread's `uv-run`, and one ran clean.

The issue left a same-thread version "plausible but untested": an engine
suspended between the check and the set. It is real. A split sweep runs a
`uv-run 'nowait` in an engine at fuel 1, 2, ..., and at the first expiry
closes the loop on the same thread. On `41fdf4c`, at fuel 8 and 9 the close
was accepted, and the resumed run raised `invalid memory reference`: it had
read the pointer before the expiry, and ran the block the close had freed.
Tearing down instead of closing failed at the same fuels.

## The design

`claim-loop!` in `(libuv private handles)`:

- The mark is a box per loop holding the claiming thread's id, or `#f`,
  taken by `box-cas!`. No lock: a lock every loop's thread shares would put
  every run of every loop behind it. 16 B a loop.
- The take, the open check and the owner transfer are one `one-step`, so no
  engine of the claiming thread comes between them. The open check comes
  after the take, so a run that claims after a close finds the loop closed.
  A closed loop is answered before any claim: it never reopens.
- A refused claim changes nothing: not the mark, not the owner.
- `memory-order-acquire` after the take, `memory-order-release` before the
  clear. On arm64 `box-cas!` is a bare `ldxr`/`stxr` with no ordering (two
  reviewers dumped the code), and fails now and then with the box unchanged,
  so a failed take is a refusal only when the mark is really held.
- `release-loop!` gives back only this thread's claim, and raises
  (`assertion-violation`) on any other: a release that cleared another
  thread's claim is the defect the review found in the exit.

The verbs:

- `uv-run` and every run of a teardown's drain go through one `run-step!`:
  claim (taking the loop over), `uv_run`, then take the pending callback
  error and release, as one interrupt-free step.
  `take-pending-callback-error!` asserts that this thread holds the claim.
- `uv-loop-close!` is one interrupt-free step (`close-step!`): claim without
  taking the loop over, `uv_loop_close`, the record closed and freed,
  release. It answers a status, and the verb raises after.
- `uv-loop-teardown!` is steps that each hold the claim only while they call
  libuv: `start-teardown!` (one step: claim, cancel requests, begin every
  handle's close, release), drain runs (`run-step!`), and `close-step!`.
  Nothing in a claimed step raises; the teardown answers what to raise, and
  no `guard` sits around it.
- `call-with-uv-loop`'s exit takes a claim back only when the mark names its
  own thread, and hands it to the teardown's first step. A failed teardown is
  claimed again for good (an abandoned run, #45), unless it failed because
  another call took the claim between its steps.
- `uv-run` keeps its unfenced first check of the mark only to keep refusing
  `'loop-running` before an unknown mode.

## The review, and what it changed

A max-effort review of the first version (10 finder angles, 18 verifiers, a
gap sweep) reported 15 findings. The first version kept the mark as `#t`,
held the teardown's claim across the whole teardown inside a `guard`, and
left `call-with-uv-loop`'s exit as it was.

| Finding | Measured on the first version | Now |
|---|---|---|
| The exit took "marked and owned by this thread" for its own claim; a close claims without moving the owner | another thread's close: SIGABRT (double `uv_loop_close`) 3 of 3 | the mark names its holder; a close-shaped claim another thread holds is refused by name |
| `claim-loop!` stored the mark before the owner, so the exit also took another thread's fresh run claim for its own | hand-off probe: SIGABRT 3 of 3; base 9,000 rounds clean | as above |
| The exit cleared its claim and then re-claimed, and re-marked over another thread's claim on a refusal | 15 of 2,000 loops left claimed with no run in them (base worse) | 0 of 2,000; the exit never re-claims after a refusal |
| A dropped close or teardown stranded the loop at almost every expiry | teardown 2,997 of 3,000 drop points (base 624, inside `uv_run` only); close 8 of 11 | close: none; teardown: 1 expiry, the same as a dropped `uv-run` |
| The teardown's `guard` gave the claim back over a fault out of `uv_run` | the loop was enterable again | no guard; a fault keeps the claim |
| A concurrent close of a closed loop was refused | ~5% of closes, ~2% of teardowns | 0 of 40,000 |
| The teardown's `guard` cost ~400 B | make + teardown 970 B | 576 B (base 946) |

The review's other findings were in the tests and this log: the close race
could not see a broken claim (an empty loop has no callback to witness it);
suite plumbing could raise outside a row; one row leaked a loop into the
memory-gated process; the drain-bound row waited ~1.4 s; a judge lacked a
case its contract promised; one row depended on argument order; the log
misreported M2 and miscounted its table. Each is fixed below.

## Cost

A scratch benchmark (1,000,000 runs; 100,000 make-and-close cycles), base and
the final code alternating, three runs each, load 4–5:

| Call | Base | Fix |
|---|---|---|
| `uv-run 'nowait` on an empty loop | 81.3–83.2 ns, 16 B | 99.6–101.7 ns, 16 B |
| `make-uv-loop` + `uv-loop-close!` | 448 B | 464 B |
| `make-uv-loop` + `uv-loop-teardown!` | 946 B | 576 B |

Of the run's +17 ns, no one piece dominates: variants without the pending
take's assertion, without the release's interrupt-free step, or with a plain
store for the release each saved 2–5 ns. The first version cost +5 ns; the
checks the review asked for cost the rest.

## The tests

`tests/test-loop-claim.sps`, 36 rows, 1.2 s:

- **From another thread, while this thread runs the loop** (3): each verb is
  refused `'loop-running`, and inside the run the loop is still claimed and
  still this thread's.
- **Ownership and refusal order** (2): a close refused `EBUSY` on another
  thread leaves the owner; a `uv-run` with an unknown mode on a running loop
  is refused `'loop-running`.
- **Every way out gives the claim back** (6): a run whose callback raised, a
  close refused `EBUSY`, a teardown that re-raises a close callback's error,
  a teardown at its drain bound (an async that stops each run and re-sends
  itself, so no run waits), a second close of a closed loop, and a release
  by a thread that does not hold the claim, which is refused.
- **An escaping teardown on another thread** (2): the loop is left claimed
  by that thread and owned by it; then the suite takes it back.
- **`call-with-uv-loop`'s exit** (1, plus a race below): another thread
  holds a claim taken as a close takes it; the exit refuses it by name, and
  the claim stays that thread's.
- **Engine splits** (6): close, teardown, and another run, each with a
  precondition that the split landed before the run's claim and inside it.
  Each fuel's teardown result is checked, and a raise between fuels ends the
  sweep as a row's evidence.
- **Engine drops** (3): a dropped close never leaves its loop claimed and a
  retry closes it; a dropped teardown of an empty loop leaves it claimed at
  no more expiries than a dropped `uv-run` does, and a retry finishes it; a
  precondition that every sweep was dropped and a dropped run did strand.
- **Races**, skipped under Valgrind (13): two runners on one loop (every
  call runs or is refused, at most one callback at once, every callback
  finds the claim naming its own thread, the claim free afterwards, two
  preconditions); a runner against a teardown and against a close, 200 loops
  each (the close race's timers close themselves after three fires, so its
  callbacks witness the claim while the closer tries); two threads closing a
  closed loop; bodies left from a timer callback while another thread runs
  every unclaimed loop it sees.

Rule 7 of `tests/test-source-rules.sps` (2 rows) keeps `set-loop-holder!`,
which sets the mark outright for the tests' forgeries, out of `src/`.

## Mutations

Each row copies the worktree's `src/` fresh into the scratchpad, applies
exact replacements (each must match once), and runs `test-loop-claim.sps`
against the copy. Control: 0 failures. Final sweep on the final code:

| # | Mutation | Result |
|---|---|---|
| M1w | the claim always takes the mark (no CAS) | 20 FAIL, among them all three "from another thread", the exit row, and every race row |
| M1t | check-then-set inside the step | 4 FAIL: two runners, the teardown race and the close race |
| M2 | a refused claim clears the mark | 20 FAIL, including the close and teardown "from another thread" rows |
| M3 | a refused claim takes the owner | 2 FAIL: the close and teardown "from another thread" rows |
| M5 | a close refused `EBUSY` keeps its claim | 4 FAIL: both `EBUSY` rows, the close race and its precondition |
| M6 | a run never gives its claim back | 32 FAIL |
| M8 | a close takes the loop over | 1 FAIL: the `EBUSY`-on-another-thread row |
| M11 | the pending error taken after the release | 34 FAIL: the assertion fires in every run |
| M12 | no unfenced first check in `uv-run` | 1 FAIL: the unknown-mode row |
| M14 | the deferred list reset before the claim | 1 FAIL: the deferral split sweep |
| N1 | the exit asks "marked and owned by me" | 18 FAIL, the exit row first |
| N3 | the exit re-claims after a refusal too | 1 FAIL: the exit race |
| N4 | a closed loop is claimed before it is answered | 1 FAIL: two threads closing a closed loop |
| N5 | a close is not one step | 2 FAIL: the close drop row and the teardown drop row |
| N6 | the teardown's first step is not one step | 1 FAIL: the teardown drop row |
| N7 | `release-loop!` clears whatever the mark holds | 1 FAIL: the release-by-another-thread row |
| N9 | the teardown holds its claim across its steps | 5 FAIL: the drain-bound row, the close split row and its precondition, the teardown drop row, and the exit race's precondition |
| M4 | the open check read before the take | survived, see below |
| M9 | the teardown's first step does not take the loop over | survived, see below |
| M10a | no acquire fence after the take | survived, see below |
| M10b | no release fence before the clear | survived, see below |
| M13 | a failed `box-cas!` is always a refusal | survived, see below |
| N2 | the exit releases its claim, then tears down as any caller | survived, see below |
| N8 | `take-pending-callback-error!` without its assertion | survived, see below |

24 mutants: 17 fail by name, 7 survive. N5 aborted the process (a retried
close of a half-closed loop) until the drop sweeps stopped taking back loops
a dropped close or teardown left claimed; it now fails by name.

The first version's sweep, for the record: 18 mutants, 13 caught. Its log
said M2 failed all three "from another thread" rows, but the `uv-run` one
cannot fail under M2 (the unfenced first check refuses before the claim),
and the table had 17 rows, 12 caught. Both were wrong in the log, not in the
code.

### Uncovered, and why

- **M4** (open check before the take). No expiry of the split sweeps lands
  between the read and the step: the read is the last call before `one-step`
  disables interrupts. Across threads the window is the few instructions
  between the read and the compare-and-set.
- **M9** (the first step keeps the owner). Equivalent: every drain run takes
  the loop over, so the owner is the teardown's thread before any callback
  runs.
- **M10a/M10b** (fences). No test here can observe a reordering on demand.
  Two reviewers confirmed in the generated arm64 code that `box-cas!` carries
  no ordering of its own and that each fence emits a `dmb`; the fences stay
  because the release/acquire pairing is what hands libuv's state from one
  holder to the next.
- **M13** (spurious failure). Real on arm64 (a single `ldxr`/`stxr`), but no
  run here produced a refusal from an unset mark; a spurious refusal would
  surface as a `'loop-running` on an idle loop.
- **N2** (no hand-off in the exit). Equivalent under the final design: a
  call that gets in between the release and the teardown is a call that
  could get in between the teardown's steps anyway, and the exit then leaves
  the loop to it instead of re-claiming. The hand-off only makes the
  handles' closes begin before another call can get in.
- **N8** (the assertion itself). It is the check that turns M11 from a
  survivor (the first version's sweep) into 34 named failures.
