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

- `try-construct-handle` checks the owner in its interrupt-free step, beside
  the loop's open check, and its `owned?` flag is gone, so no constructor can
  opt out. `construct-handle` and `uv-accept!` raise `&uv-wrong-thread` for
  the step's `'wrong-thread` (`wrong-thread-refusal`).
- `uv-spawn!`'s step checks the owner after the loop's open check, and
  `spawn-refusal` raises `&uv-wrong-thread` for it.
- `uv-getaddrinfo!` and `uv-getnameinfo!` have no step yet, so they call
  `require-loop-thread` on entry, after `require-open-loop`.

The first draft also put `require-loop-thread` on entry to the four
constructors and `uv-spawn!`, ahead of their steps. Nothing between those
entries and the steps allocates, so the step refuses every call the entry
check would: a check no mutation can break, and not a decision any test can
hold. Those entry checks were removed before the sweep below.
`make-uv-async` keeps its own, which refuses before it makes its send fence,
and `uv-accept!` its server's (`require-open-tcp`).

## Red before green

On `41fdf4c`, with only the tests applied:

| Suite | Rows that failed |
|---|---|
| `tests/test-constructor-owner.sps` (new) | 14 of 29: the refusal row and the hand-off row for each of `make-uv-timer`, `-tcp`, `-pipe`, `-signal`, `uv-spawn!`, `uv-getaddrinfo!`, `uv-getnameinfo!`. Each off-thread call made its handle or request: `(seen (1 (made)) left ((registry 1) (timer 1) (block 1)))` |
| `tests/test-constructors.sps` | 2: the handoff sweep's two rows. The four constructors made their handle after the hand-off at fuel 1; `uv-accept!` made its client at fuel 10, past its entry check and before its step |
| `tests/test-process.sps` | 2: the new `hand-off-loop` state sweep, whose fuel-1 run spawned after the hand-off (`step-not-run ((spawned) (7 #f) handed-off …)`), and the reach row |

`make-uv-async` and `uv-accept!` passed the new suite's rows on the base,
as they should: both were already checked on entry.

## The sweep

Each mutation ran in a `--no-hardlinks` clone in the scratchpad, with `src/`
reset before each row and one exact text edit applied (the runner aborts
unless the target occurs exactly once). Every mutant failed by name.

| # | Mutation | Rows that failed |
|---|---|---|
| M1 | `try-construct-handle` drops its owner check | owner suite: refusal and hand-off rows for timer, tcp, pipe, signal (8); test-constructors: both handoff rows |
| M2 | `loop-owned-here?` always answers `#t` | owner suite: those 8 plus `uv-spawn!`'s two; test-constructors: both handoff rows |
| M3 | `loop-owned-here?` always answers `#f` | owner suite: all 29, the creator's and the handed-to thread's rows included. This is the positive control: a check that refused everyone fails here |
| M4 | `spawn-step!` drops its owner check | owner suite: `uv-spawn!`'s refusal and hand-off rows; test-process: `hand-off-loop` and the reach row |
| M5 | `spawn-refusal` drops its `'wrong-thread` case | owner suite: `uv-spawn!`'s two rows (the step's refusal surfaced as `&uv-invalid-argument`) |
| M6 | `uv-getaddrinfo!` drops its `require-loop-thread` | owner suite: its two rows |
| M7 | `uv-getnameinfo!` drops its `require-loop-thread` | owner suite: its two rows |
| M8 | `uv-accept!` drops its `'wrong-thread` case | test-constructors: the handoff sweep row (an accept resumed after the hand-off raised `&uv-invalid-argument`) |
| M9 | `construct-handle` drops its `'wrong-thread` case | owner suite: the 8 constructor rows |
| M10 | `wrong-thread-refusal` swaps `expected` and `actual` | owner suite: the 8 constructor rows and `uv-spawn!`'s two |
| M11 | `wrong-thread-refusal` names another verb | the same 10 |
| M12 | the owner check moves after `alloc-block`, refusing without freeing | owner suite: the four constructors' refusal rows (`left ((block 1))`) and the final counters row |

M9's first run also failed the owner suite's two final balance rows. The
`&uv-invalid-argument` it raised escaped `attempt`, which caught only
`&uv-wrong-thread`, so the row never reached its loop's teardown and the loop
leaked into the suite's totals. `attempt` now answers any other raise as
`(raised …)` evidence, so a row always tears its loop down; rerun, M9 failed
only its own 8 rows, and M5 its own 2.

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

On `f8e6fce` plus the `attempt` change: `make test` (28 suites), `make
test-memory` (ASan), `check-purity`, `check-help`.
