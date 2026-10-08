# The owner check in every verb that makes something on a loop (#79): evidence and mutations

Issue #79, found reviewing #77: only `make-uv-async` checked that its caller
owned the loop. `make-uv-timer`, `-tcp`, `-pipe` and `-signal`, `uv-accept!`'s
client, `uv-spawn!`, `uv-getaddrinfo!` and `uv-getnameinfo!` called libuv from
any thread. The issue's probe had a second thread make 20,000 timers on a loop
the main thread was running. libuv's handle queue was corrupted in 11 of 13
runs, and `uv-loop-teardown!` answered `ok` every time.

macOS arm64, Chez 10.4.1 threaded, vendored libuv 1.52.1. Base: main
`41fdf4c` (#77). Branch `fix/constructor-owner`.

## The shape

- A step that makes something on a loop takes the loop's pointer from
  `owned-loop-ptr`: `open-loop-ptr` plus the owner check. That covers
  `try-construct-handle` (every handle constructor, `uv-accept!`'s client;
  its `owned?` flag is gone) and `uv-spawn!`'s step. `construct-handle`,
  `uv-accept!` and `spawn-refusal` raise `&uv-wrong-thread` for the step's
  `'wrong-thread` (`wrong-thread-refusal`). `open-loop-ptr` stays as on
  main, for #78's claim, which decides ownership rather than checking it.
- `uv-spawn!` also checks on entry, so the wrong thread is told so before
  its arguments are read.
- `uv-getaddrinfo!` and `uv-getnameinfo!` have no step yet, so they call
  `require-loop-thread` on entry, before reading their arguments.
- `uv-cancel!` checks the owner of the request's loop, which a DNS request
  now carries (`req-loop`, an optional fifth argument to its record's
  constructor).

The first draft also put `require-loop-thread` on entry to the four
constructors, ahead of their steps. Nothing between those entries and the
steps allocates, so the step refuses every call the entry check would: a
check no mutation can break. Those entry checks were removed. `uv-spawn!`'s
was removed too at first, then restored after the review (below): there the
entry check decides what a wrong-thread caller with bad arguments is told,
and a row holds that. `make-uv-async` keeps its own, which refuses before it
makes its send fence, and `uv-accept!` its server's (`require-open-tcp`).

## Red before green

On `41fdf4c`, with only the first round's tests applied:

| Suite | Rows that failed |
|---|---|
| `tests/test-constructor-owner.sps` (new) | 14 of 29: the refusal row and the hand-off row for each of `make-uv-timer`, `-tcp`, `-pipe`, `-signal`, `uv-spawn!`, `uv-getaddrinfo!`, `uv-getnameinfo!`. Each off-thread call made its handle or request: `(seen (1 (made)) left ((registry 1) (timer 1) (block 1)))` |
| `tests/test-constructors.sps` | 2: the handoff sweep's two rows. The four constructors made their handle after the hand-off at fuel 1; `uv-accept!` made its client at fuel 10, past its entry check and before its step |
| `tests/test-process.sps` | 2: the new `hand-off-loop` state sweep, whose fuel-1 run spawned after the hand-off (`step-not-run ((spawned) (7 #f) handed-off …)`), and the reach row |

`make-uv-async` and `uv-accept!` passed the new suite's rows on the base,
as they should: both were already checked on entry. The review round's rows
(`uv-cancel!`, arguments read after the check) are held by M4, M13–M15
below, each a mutant of exactly the code they guard.

## The sweep

Each mutation ran in a `--no-hardlinks` clone in the scratchpad, with `src/`
reset before each row and one exact text edit applied (the runner aborts
unless the target occurs exactly once). Every mutant failed by name. This is
the second sweep, on `1da613c` (the review fixes); the first, on
`f8e6fce`, had 12 mutants of the first shape and all failed by name too.

| # | Mutation | Rows that failed |
|---|---|---|
| M1 | `owned-loop-ptr` drops its owner check | owner suite: refusal and hand-off rows for timer, tcp, pipe, signal (8); test-constructors: both handoff rows; test-process: `hand-off-loop` and the reach row |
| M2 | `owned-loop-ptr` compares the owner with itself | owner suite: the same 8 |
| M3 | `owned-loop-ptr` refuses every thread | owner suite: all 35, the creator's and the handed-to thread's rows included. The positive control: a check that refused everyone fails here |
| M4 | `uv-spawn!` drops its entry check | owner suite: `uv-spawn!` "refused before its arguments are read" |
| M5 | `spawn-refusal` drops its `'wrong-thread` case | test-process: `hand-off-loop` (a spawn resumed after the hand-off raised `&uv-invalid-argument`) and the reach row |
| M6 | `uv-getaddrinfo!` drops its `require-loop-thread` | owner suite: its refusal, arguments and hand-off rows (and `uv-cancel!`'s refusal row: see below) |
| M7 | `uv-getnameinfo!` drops its `require-loop-thread` | the same for `uv-getnameinfo!` |
| M8 | `uv-accept!` drops its `'wrong-thread` case | test-constructors: the handoff sweep row |
| M9 | `construct-handle` drops its `'wrong-thread` case | owner suite: the 8 constructor rows |
| M10 | `wrong-thread-refusal` swaps `expected` and `actual` | owner suite: the 8 constructor rows |
| M11 | `wrong-thread-refusal` names another verb | the same 8 |
| M12 | the constructor step checks the owner after `alloc-block`, refusing without freeing | owner suite: the four constructors' refusal rows (`left ((block 1))`) and the final counters row |
| M13 | `uv-cancel!` drops its owner check | owner suite: `uv-cancel!`'s refusal and hand-off rows |
| M14 | `uv-getaddrinfo!` checks the owner after reading its arguments | owner suite: `uv-getaddrinfo!` "refused before its arguments are read" |
| M15 | getaddrinfo requests carry no loop | owner suite: `uv-cancel!`'s three rows |

In the first sweep, M9's run also failed the owner suite's two final
balance rows. The `&uv-invalid-argument` it raised escaped `attempt`, which
caught only `&uv-wrong-thread`, so the row never reached its loop's
teardown and the loop leaked into the suite's totals. `attempt` now answers
any other raise as `(raised …)` evidence, so a row always tears its loop
down.

M6 and M7 also failed `uv-cancel!`'s refusal row, with the refusal right
and `left ((fds 1))` or `((fds -1))`. That row's fixture started a
"localhost" lookup, and the resolver opens and closes descriptors of its own
on libuv's worker thread while it runs, so the row's descriptor count raced
it. The mutants only moved the timing. The fixture now runs its lookup to
completion before any row counts; the owner check comes before `uv-cancel!`
reads the request, so a completed request still tells a refusing build from
one without the check (M13 answers `#f` from the wrong thread).

## The review

A high-effort /code-review of `f8e6fce..076a598` reported nine findings.

| Finding | Outcome |
|---|---|
| `uv-cancel!` unchecked: from another thread it reads the request's pointer and calls `uv_cancel` while the loop's thread can complete the request and free its block | Fixed (M13, M15) |
| A row whose thread never answered tore down the loop that thread could still be using | Fixed: such a row leaves the loop alone and fails with `left-to-its-thread` |
| The owner check belonged in the loop-pointer read every step takes, not beside it | Fixed: `owned-loop-ptr` |
| Without its entry check, a wrong-thread `uv-spawn!` with bad arguments was told `&uv-invalid-argument` | Fixed: the entry check is back, held by a row (M4); the DNS verbs gained the same row (M14) |
| The new suite copies fd-count, balance, residue and accept-prepare from test-constructors | Skipped: a shared fixture library is the deferred test-suite cleanup (#66 item 4, now #81) |
| `wrong-thread-refusal` reads the owner after the step, so `expected` can differ from what the step saw | Skipped: the field is informational, and the step's status would have to carry the owner |
| `require-loop-thread` duplicates the new helpers | Skipped: it sits beside the loop record #78 rewrites; folding it in is a one-line follow-up after both land |
| docs/api.md's condition summary does not list the libraries that now raise `&uv-wrong-thread` | Skipped: that list predates DNS, timer and tcp and never listed them |
| The owner field is read without a barrier | No change: a correct hand-off orders the two threads through the user's own synchronisation; a racing one is the residual below |

Uncovered by design:
- A call that races the hand-off itself (one already past its check when
  the other thread's `uv-run` takes the loop) is not refused. Closing that
  would need the constructors and `uv-run`'s claim (#78) to share a lock held
  across libuv's init. docs/api.md makes it the caller's, and ADR-0019's #79
  amendment records it.
- The DNS verbs' check is on entry only: an engine can still suspend one
  between the check and its native call while the loop changes hands. They
  have no step yet (ADR-0019 decision 3's amendments list them).

## Gates

On `076a598`: `make test` (28 suites), `make test-threading`, `make
test-memory` (ASan), `check-purity`, `check-help`. On the final head: see
the PR.
