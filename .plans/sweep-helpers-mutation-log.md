# The step suites' shared sweep helpers (#103): evidence and mutation log

2026-10-09. The engine-sweep suites each carried their own copy of the
helpers that read their sweeps, and the copies had drifted:

- `bad-runs` took its arguments in two orders, and test-owner-refusal's
  took one, with its predicate fixed inside;
- runs had two shapes: `(fuel verdict expired?)` from `sweep-fuels`
  (handle-steps, request-steps, owner-refusal) and `(fuel . verdict)` from
  three drivers of the suites' own (stream, constructors, process-steps);
- `reach` came in three forms: first and last, first and every-fuel and
  last (process-steps), and refused-in-some-run and last (owner-refusal);
- `balance` had three shapes and `residue` three bodies; `run-verdict`
  took a finish answer in two suites and a lock in a third, and
  test-stream wrote the same check under another name (`with-residue`)
  and once more inline;
- `me` was defined in six suites and bound locally in a seventh,
  `other-thread` in five, and test-constructors and test-process wrote
  it out as `(+ me 1)` and `(+ (get-thread-id) 1)`.

Each helper now lives once, in `(uv-sweep)`, and
`tests/test-sweep.sps` holds every one. Its census row, "each name
(uv-describe) and (uv-sweep) export is defined in its own library
alone", fails a new definition of any exported name, procedure or
variable, at any depth of any source directly under `tests/`.

## The shape settled on

- A run is `(fuel verdict expired?)`, as `sweep-fuels` makes it. The
  three suites with drivers of their own now sweep with `sweep-fuels`,
  through a one-line adapter that answers whether an expiry reached the
  run from its verdict, as their drivers did. A raise between runs now
  keeps the runs before it, where their drivers kept none.
- `(bad-runs good? sweeps)`: the predicate first, as `filter` takes it.
- `(reach sweeps)` answers each sweep's first verdict and its last;
  `(reach-any verdict sweeps)` answers whether some run had the verdict,
  for test-owner-refusal, whose first runs end before the verb's checks.
- A balance is a list of `(name . count)`, which each suite still reads
  itself (the registry, the debug counters, the descriptors it counts).
  `(residue before after)` is pure.
- `(checked-verdict verdict finished before balance)` reads the balance
  itself. A run's tidying is often an argument (`(finish! …)`), and Chez
  evaluates arguments right to left, so a balance read in an argument
  could come before the tidying.
- `me` and `other-thread` are the library's. Chez instantiates a
  program's libraries on its main thread before the body runs, measured
  with a library whose body printed its thread id and a program that
  first referenced it from a forked thread: id 0, before the body, both
  interpreted and compiled.

Two names collided with the census without being copies, both in
test-loop-claim: a thread body called `other-thread`, and a predicate
over race verdicts called `stuck?`. They are renamed `claim-and-hold` and
`race-stuck?`.

## What changed in what the rows ask

- test-process-steps' reach rows lose the every-fuel column. It held that
  suite's own driver to running every fuel from 1; the driver is now
  `sweep-fuels`, which test-sweep's "sweep-fuels runs fuel 1 up" holds.
  H21 below is that mutant, killed by test-sweep and no longer by
  test-process-steps.
- test-stream's shrink and segment-list reach rows dropped the first
  run's fuel (`(1 refused)` became `refused`), for the same reason, and
  their bad-run rows answer `(name fuel verdict)` where they answered the
  expired? column too.
- test-constructors' held init lock reads `(verdict finish
  init-lock-held)` where it read `(verdict init-lock-held)`, and a run
  that left interrupts disabled now also has a held lock released.
- `sweep-fuels` gives up at its cap or past it (`>=`, was `=`). H21, a
  driver striding by two, ran past an even cap and hung test-sweep at
  1 GB for 648 s until killed; with `>=` it fails six rows by name in
  under a second.

## On a correct build

Each migrated suite was run on main (27520e3) and on the branch, macOS
arm64, and the outputs compared. test-handle-steps, test-request-steps,
test-constructors, test-process-steps, test-owner-refusal, test-address
and test-constructor-owner printed the same bytes, every fuel map
included. test-stream and test-process differed only in their race counts
and copy timings, which vary run to run.

## Mutations

Each ran in a scratch copy of the tree outside the repo, the source-
reading suites with the copy as their working directory, on macOS.
"Killed" is the suite failing rows by name; the counts are its failing
rows. Every helper mutant ran against test-sweep and the step suites that
use the helper. A helper mutant the step suites survive changes only what
a failing build would show, and test-sweep's rows are what hold it.

### The helpers (tests/uv-sweep.sls)

| ID | Mutation | test-sweep | the step suites |
|---|---|---|---|
| H1 | `bad-runs` keeps the runs GOOD? accepts | its row | every bad-run row: owner-refusal 1, handle-steps 8, request-steps 7, stream 8, constructors 4, process-steps 4 |
| H2 | `bad-runs` answers the expired? column as the verdict | its row | survives: a correct build has no bad runs |
| H3 | `reach` answers the last verdict as the first | its row | every reach row: handle-steps 8, request-steps 7, stream 6, constructors 4, process-steps 4 |
| H4 | the last verdict read from the expired? column | reach, reach-any | every reach row, owner-refusal's included |
| H5 | `reach-any` compares with `eq?` | its row (a list verdict) | owner-refusal survives: it asks for a symbol |
| H5b | `reach-any` always `#f` | its row | owner-refusal's reach row |
| H6 | `expected-reach` ends `'refused` | its row | handle-steps 8, request-steps 5, stream 5, constructors 2 |
| H7 | `fuel-map` compares with `eq?` | fuel-map, report! | survives: the maps are informational |
| H8 | a stretch's last fuel kept as its first | fuel-map, report! | survives, the same |
| H9 | `report!` drops the kind | its row | survives, the same |
| H10 | `untouched?` true of any pair holding `untouched` | its row | survives: no verdict here holds it past its head |
| H11 | `interrupts-enabled?` always `#t` | its row, checked-verdict's interrupts row | survives, test-process too: a correct build never leaves them disabled |
| H11b | `interrupts-enabled?` always `#f` | 3 rows | handle-steps 24, request-steps 17, stream 9, constructors 9, process-steps 9, test-process 4 |
| H12 | `residue`'s deltas negated | residue, checked-verdict | survives, address and constructor-owner too: a correct build leaves nothing |
| H13 | `residue` keeps unchanged counts | residue, checked-verdict | handle-steps 24, request-steps 17, stream 8, constructors 12, process-steps 9, address 2, constructor-owner 13 |
| H14 | `checked-verdict` reports the residue before the untidy finish | its row | survives: a correct build finishes every run |
| H15 | `checked-verdict` leaves interrupts disabled | its interrupts row | survives, as H11 |
| H16 | `me` another thread's id | its row | owner-refusal 4, handle-steps 10, request-steps 4, process-steps 4, constructor-owner 23. Stream and constructors survive, as their local `me` would have: their handoff rows map any `&uv-wrong-thread` to a symbol, reading no field, and the run's next `uv-run` claims the loop for this thread (`claim-loop!` with take-owner), whoever the hand-back named |
| H17 | `other-thread` is `me` | its row | owner-refusal 2, handle-steps 4, request-steps 4, stream 2, constructors 2, process-steps 2, test-process 2 |
| H21 | `sweep-fuels` strides by two | six rows (with `=`: hung, see above) | process-steps survives (its every-fuel column is gone) |

### The census

| ID | Mutation | Killed by |
|---|---|---|
| H18 | test-timer defines its own `fuel-map` | the census row: `(fuel-map "tests/test-timer.sps" "tests/uv-sweep.sls")` |
| H19 | test-loop defines `me` inside a procedure | the census row |
| H20 | the census reads no exports | the census row |

### The drivers the three suites moved onto

| ID | Mutation | Killed by |
|---|---|---|
| D1 | test-stream's adapter says no run expired | stream's 4 reach rows |
| D2 | test-constructors', the same | constructors' 4 reach rows |
| D3 | test-process-steps', the same | process-steps' 4 reach rows and its reuse seed |
| D4 | test-owner-refusal's sweep stops at every verdict | owner-refusal's reach row |

### Source defects, run against main's suites and the branch's

| ID | Mutation | main | branch |
|---|---|---|---|
| RS2 | `uv-write!`'s step checks no owner (`open-handle-ptr`) | stream's handoff row | the same row, the same actual |
| RP2 | `uv-process-kill!` with no step (`begin`) | process-steps' split, reuse and handoff rows | the same rows, the same actuals but the child pids |
| RC | `try-construct-handle` checks no owner (`open-loop-ptr`) | constructors 2, constructor-owner 8, owner-refusal 1 | the same rows, the same actuals |
| RS | `uv-stream-write-queue-size`'s step checks no owner | survives | survives |
| RP | `uv-process-pid`'s, the same | survives | survives |

RS and RP survive both trees: nothing between those verbs' entry checks
and their steps can trap, so the entry check refuses every handed-off run
(#113's log lists them among the fourteen never refused by their step).

## What is not covered

- **`checked-verdict`'s order against its arguments.** That it reads the
  balance after them is the procedure call's own semantics; no mutation
  of the library can break it, and a call site that read the balance in
  an argument instead would fail its suite's rows on a correct build.
- **Copies under other names.** The census reads names. test-addrinfo's
  `sweep-reach` and `bad-rows` (one sweep's rows, not named sweeps),
  test-timer's `close-sweep-reach` (a list of symbols) and test-process's
  spawn and state sweeps (drivers of their own, with `every-fuel` and
  `wrong-runs`) read other shapes and were left as they are.
