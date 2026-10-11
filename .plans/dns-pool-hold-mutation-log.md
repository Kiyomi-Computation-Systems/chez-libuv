# #127: the queued-tail teardown lost every draw: mutation log

Branch `test/dns-queued-tail-127`, on main 73190a3, 2026-10-11. macOS
arm64 (Darwin 25.6, Chez 10.4.1, Homebrew libuv 1.52.1) unless a row says
otherwise. The Linux rows ran in the arm64 Docker mirrors: Ubuntu 26.04
with apt libuv 1.51.0 (`chez-libuv-resolute-scratch:10.4.1`), and the
Valgrind image on the vendored leg (libuv v1.52.1).

## What failed

On CI run 38013045006 (ubuntu-26.04, libuv 1.51.0), test-dns's
queued-tail teardown row lost all 16 of its draws on a correct build:

```
  [informational] queued-tail teardown: cancel never won in 16 attempts (max 16)
FAIL queued-tail teardown: the sweep cancelled the queued tail within the attempt bound
  actual: (never-cancelled-in 16 attempts final-tail-err no-error)
FAIL queued-tail teardown: the cancelled tail delivered EAI_CANCELED with host and service #f
  actual: (no-error (host "127.0.0.1") (service "8080"))
```

The row queued four numeric lookups and a getnameinfo tail on a pool
pinned to one worker, then tore the loop down in the same turn. It needed
the tail still queued when the teardown's sweep cancelled it, and retried
up to 16 times, at a loss rate of about 1% a draw
(`.plans/dns-stage-5-mutation-log.md`). The double-cancel row bet on the
same state the same way.

## What was measured

A scratch copy's sweep logged each `uv_cancel`'s pointer and result, and
could cancel the tail first or last instead of in the registry's order.
The probe repeated the teardown attempt 500 times per run, with no stop at
the first win.

| Where | Sweep order | Won / 500 | Longest run of losses |
|---|---|---|---|
| macOS | registry | 497 | 1 |
| macOS | tail first | 497 | 1 |
| macOS | tail last | 499 | 1 |
| Ubuntu 26.04 | registry | 488 | 1 |
| Ubuntu 26.04 | tail first | 494 | 1 |
| Ubuntu 26.04 | tail last | 489 | 1 |

- **Two kinds of loss.** In one, every cancel answered `EBUSY`: the
  worker had finished all five lookups before the sweep began. In the
  other, the sweep cancelled the lookups queued ahead of the tail first,
  and the worker reached the tail before the sweep did. On Linux both
  kinds were among the first six losses printed in the registry's order
  and with the tail last; with the tail first all six were the first
  kind. macOS's seven losses were six of the first kind and one of the
  second (tail last).
- **The sweep's order is fixed within a process.** The registry is an
  eqv table keyed by request address, and malloc handed each attempt the
  same five addresses (499 of 499 on Linux). The tail sat at the same
  place in the sweep every time. But the order moved Linux's loss rate
  only between 1.2% and 2.4%, and losses never came two in a row.

So nothing measured here explains 16 losses in a row. Whatever held the
runner's window open for every attempt was not reproduced locally, and
CI was billing-blocked, so it could not be measured on a runner. The fix
does not depend on knowing it.

## The change

A *pool hold* (`src/libuv-shim.c`, dev builds only): a threadpool item
that keeps the worker running it until the suite releases it, or until a
10 s bound passes. Each of the two rows queues one, waits until the
pool's only worker is inside it, and only then queues its lookups. No
lookup can start until the release, so the rows' cancels find their
requests queued every time.

- The double-cancel row releases its hold once both cancels have
  answered. Four numeric lookups queued ahead of the request then run for
  real, so the row still cancels a request out of a nonempty queue, and
  still sees real completions after a cancelled one.
- The teardown row cannot release between its sweep and its drain, which
  are one call, so its lookups' callbacks release it. A cancelled
  lookup's callback runs while the worker is still held.
- Neither row retries now. The teardown row also asserts that all four
  getaddrinfo requests were cancelled, which the race made impossible to
  assert.
- Each row's first row after "did not raise" is a precondition: the
  worker was inside the hold before the lookups were queued (`'waiting`),
  the hold ended by release (`'released`, not `'timed-out`), its
  after-work callback ran (`'finished`), and it was freed.
- The bound is a backstop: a build whose sweep cancels nothing runs no
  callback, so nothing releases the teardown row's hold. The rows then
  fail by name after 10 s instead of hanging the suite. `settle-hold!`,
  which ends each double-cancel attempt, waits past the bound, so even a
  hold that ignores its release ends before a later row runs.
- A freed hold forgets its block, so a release after the free is ignored
  rather than handed freed memory, and a hold its worker is still in is
  never freed.
- The hold's seven entries are resolved only when the shim has them. A
  shim without one fails the entries row and every row that holds the
  pool by name, and the suite still prints its totals.
- Two seeded rows hold the hold itself: one left unreleased past a 1 ms
  bound reads `'timed-out`; one released while its worker waits reads
  `'released`, is kept by a free before it finishes, and ignores a
  release after its free. They pin `hold-state`'s numbers to the shim's
  enum, which crosses as integers.
- `tests/check-prod.sps` fails a release shim that exports any of the
  hold's seven entries, and rule 12 of `tests/test-source-rules.sps` holds
  that list to every `chez_uv_debug_` function the shim defines, each
  inside the `#ifdef`. ADR-0002 is amended for the new kind of export.

## Red before the fix

A 2 ms sleep before the teardown, and before double-cancel's first
cancel, reproduces #127's failure on main, actual for actual:

```
== main/pause-main: exit=1 (0.7 s)
  [informational] double-cancel: first cancel never won in 16 attempts (max 16)
FAIL double-cancel: a same-turn first cancel won within the attempt bound
  actual: (never-won-in 16 attempts)
FAIL double-cancel: the second cancel on the same queued node also answers #t
  actual: (second-was not-attempted)
FAIL double-cancel: the callback fired exactly once, cancelled, host and service #f
  actual: (1 no-error (host "127.0.0.1") (service "8080"))
  [informational] queued-tail teardown: cancel never won in 16 attempts (max 16)
FAIL queued-tail teardown: the sweep cancelled the queued tail within the attempt bound
  actual: (never-cancelled-in 16 attempts final-tail-err no-error)
FAIL queued-tail teardown: the cancelled tail delivered EAI_CANCELED with host and service #f
  actual: (no-error (host "127.0.0.1") (service "8080"))
# of expected passes      149
# of unexpected failures  5
```

The same sleep in the new rows: 161 passes on macOS, and 10 of 10 runs
with 161 passes on Ubuntu 26.04. Without it: main 154 passes, the new
suite 161. The double-cancel row has seven rows where it had five, the
teardown row six where it had four, and the hold adds three.

## Mutations

Each row is a fresh copy of the final tree, an exact replacement that
must match once, `make build`, and `tests/test-dns.sps` under a 60 s
timeout (`tests/test-source-rules.sps` for the rule-12 rows).

| Row | Mutation | Result |
|---|---|---|
| M3 | `loop-entries` (handles.sls) collects only `getaddrinfo-req` as requests: the Stage 3 caveat | exit 1, 0.7 s: `the sweep cancelled the queued tail` actual `no-error`; the delivery row `(no-error (host "127.0.0.1") (service "8080"))` |
| M3b | only `getnameinfo-req` | exit 1: `the sweep cancelled every queued getaddrinfo request` actual `(no-error no-error no-error no-error)` |
| M0 | `cancel-requests!` cancels nothing | exit 1, 10.8 s: the teardown's precondition `(waiting timed-out finished freed)`, the blockers' row `(no-error no-error no-error no-error)`, the tail's `no-error` and `(no-error (host "127.0.0.1") (service "8080"))`. The double-cancel rows pass: they call `uv-cancel!`, not the sweep |
| DC | `uv-cancel!` (dns.sls) never calls `uv_cancel` | exit 1: first cancel `#f`, second `(second-was not-attempted)`, delivery `(1 no-error (host "127.0.0.1") (service "8080"))`. The teardown rows pass: the sweep calls `uv_cancel` itself |
| H1 | the hold's work returns at once, never waiting | exit 1, in 6 runs of 6: the lifecycle seed `(timed-out kept released (timed-out finished) freed ignored)`, both preconditions `(timed-out timed-out finished freed)`. In 3 of the 5 repeats the teardown's race came back too, and its lookup rows failed |
| S1 | the wait for a worker to take the hold returns at once | exit 1, in 6 runs of 6: the lifecycle seed `(queued kept released (released finished) freed ignored)`, both preconditions `(queued released finished freed)` |
| H2 | a release sets nothing (it only wakes the worker) | exit 1, 30.9 s: the lifecycle seed `(waiting kept released (timed-out finished) freed ignored)`, both preconditions `(waiting timed-out finished freed)`. No later row failed |
| H4 | the hold is never queued | exit 1, 83.2 s (run with a 240 s timeout; each hold waits out the start bound and the settle cap): the timed-out seed `(queued unfinished)`, the lifecycle seed `(queued kept released (queued unfinished) kept released)`, both preconditions `(queued queued unfinished kept)`, and the teardown's lookup rows |
| H3+M0 | the hold waits with no bound, and the sweep cancels nothing | exit 124, killed at 60 s: the timed-out seed failed by name, `(waiting unfinished)`, and the suite then hung. M0 alone fails by name in 10.8 s, so the bound is what turns this into failures |
| ENUM | the shim's `RELEASED` and `TIMED_OUT` numbers swapped | exit 1: the timed-out seed `(released finished)`, the lifecycle seed `(waiting kept released (timed-out finished) freed ignored)`, both preconditions `(waiting timed-out finished freed)` |
| FREE | `free-hold!` frees a hold whatever its state | exit -6 (SIGABRT) at 0.8 s, before any row reported: destroying the condition the worker waits on aborts in libuv (`uv_cond_destroy`). That is the hazard the check exists for, but it proves nothing about the row |
| FREE' | the same, without destroying the lock | exit -6 at 10.9 s, after the lifecycle seed failed by name: `(waiting freed ignored freed freed ignored)`. The abort is the worker waking at its bound inside the freed block |
| RELEASE | `release-hold!` hands C the block even after the free | exit 1: the lifecycle seed `(raised "Exception in $oops: invalid who argument pool-hold-release (… irritants = (#f))")` |
| DISPOSE | `chez_uv_debug_pool_hold_dispose` destroys nothing | exit 0, 161 passes. **Uncovered**: destroying a pthread mutex or condition variable releases nothing on macOS or glibc, so neither a row nor the memory gate can see it skipped |
| START | the wait for a worker to take the hold has no bound, and the hold is never queued | exit 124, killed at 60 s with no row reported: the first hold waited for good. H4 alone fails by name, so this bound is load-bearing too |
| MISSING | the shim defines `chez_uv_debug_pool_hold_startedX` instead | exit 1, 0.7 s, with totals printed: the entries row `("chez_uv_debug_pool_hold_started")`, and the two seeds and both rows' 13 rows each show `(raised "Exception in pool-hold!: the shim has no pool hold …")` |
| R12a | `chez_uv_debug_pool_hold_dispose` moved into an `#else` | test-source-rules exit 1: `(outside-dev ("chez_uv_debug_pool_hold_dispose") unchecked () not-defined ())` |
| R12b | check-prod's list without `…_dispose` | exit 1: `(outside-dev () unchecked ("chez_uv_debug_pool_hold_dispose") not-defined ())` |
| R12c | check-prod's list with a `…_reset` the shim never defines | exit 1: `(outside-dev () unchecked () not-defined ("chez_uv_debug_pool_hold_reset"))` |
| control | none | exit 0, 161 passes; test-source-rules 68 |

Also not reached by any row:

- **`chez_uv_debug_pool_hold`'s cleanup when an init or the queue
  fails.** `uv_mutex_init` and `uv_cond_init` fail only when the system
  is out of resources, and `uv_queue_work` refuses only a null work
  callback, which the shim never passes. No test can make them fail
  without changing the code under test.
- **Freeing the hold when the teardown raises.** Only a failing run gets
  there: a lookup callback that raises. Without the free, the block would
  stay allocated for the rest of that run, which no row counts.

The first version of this change had no wait for a worker to take the
hold, and H1 passed its double-cancel row: the release came before the
worker reached the hold, so the hold never had to wait. The rows now
queue nothing until the worker is inside the hold, so H1 fails both. The
same version's `settle-hold!` gave up after 1024 ticks, and under H2 the
lookups it left in flight failed a later row ("boundary: every rejection
above allocated and registered nothing", `(0 6)`). It now waits past the
bound.

## check-prod

| Build | Result |
|---|---|
| dev shim (`make check-prod` after `make build`) | FAIL: `the shim exports the dev-only pool hold:` with all seven entries |
| release shim (`make prod`) | PASS: `every counter read 0 … and no dev-only entry is exported` |
| release shim with the hold compiled in (`#if 1`) | `make prod` exit 2: the same FAIL line, all seven entries |
| release shim, with native.sls resolving `chez_uv_debug_pool_hold_size` | `make prod` exit 2: check-prod's import raises `&uv-shim-unavailable` |

check-prod reports both of a dev shim's features, so that one cannot hide
the other, and ci.yml's release guard requires both lines. That step, run
verbatim on macOS:

| check-prod | Step result |
|---|---|
| as committed | exit 0: `check-prod correctly refused the dev shim, for its counters and its pool hold` |
| counter check made vacuous (`counters-moved` always `#f`) | exit 1: `::error::check-prod did not see the dev shim's counters` |
| hold check made vacuous (no entry looked for) | exit 1: `::error::check-prod did not see the dev shim's pool hold` |

## Linux

- Ubuntu 26.04, libuv 1.51.0, pkg-config build: 20 of 20 runs of the new
  test-dns passed, 161 each, and 10 of 10 with the 2 ms pause.
- The Valgrind image, vendored leg, in `make HAVE_PKG=no test-memory`:
  test-dns's own process had `definitely lost: 0 bytes in 0 blocks`,
  `suppressed: 0 bytes in 0 blocks`, `ERROR SUMMARY: 0 errors`.

## Gates

On the branch's final working tree, before its commit:

- macOS: `make test`, `make test-memory` (ASan; test-dns 161, no
  report), `make check-help`, `make check-purity`, and ci.yml's release
  guard step.
- The Valgrind image, vendored leg, as `dev`: `check-pins`, `deps`,
  `vendor`, `build`, `check-purity`, `test`, `check-memory-gate`,
  `test-memory`. Then as root: `make HAVE_PKG=no test-root`.
- pkg-config legs, `make test`: Ubuntu 26.04 (libuv 1.51.0) and Ubuntu
  24.04 (1.48.0, the floor).

## What this does not show

Why CI's run lost all 16 draws. Locally the draws were independent, and
no order of the sweep made them otherwise. The rows no longer draw at
all.

## Left as it is

The teardown's sweep cancels in the registry's order, which is a hash
table's. Cancelling the lookups queued ahead of another hands that one to
the worker before the sweep reaches it: one of the two kinds of loss
above. So a teardown can wait out a real lookup it was about to cancel. A
sweep that cancelled the newest first would never do that, but the
registry keeps no order of submission. The drain is still correct, and
this change makes the rows independent of it.
