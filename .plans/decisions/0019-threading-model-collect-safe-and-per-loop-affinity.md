# ADR-0019: Threading model — collect-safe `uv_run` and enforced per-loop affinity

- **Status:** Accepted (2026-09-19) — grounded in `spike/threading/`
- **Date:** 2026-09-19
- **Scope:** chez-libuv post-v0.5.0 (issues #19, #20)
- **Related:** [design](../2026-09-19-chez-libuv-threading-design.md),
  [plan](../2026-09-19-chez-libuv-threading-plan.md),
  [ADR-0008](0008-static-trampolines-and-handle-registry.md) (14th trampoline +
  the `__collect_safe` attribute),
  [ADR-0010](0010-loopback-integration-tests-replace-differential-oracle.md)
  (threaded-test companion),
  [ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md)

## Context

Through v0.5 the binding was single-threaded by construction: a loop, its
handles, and the process-global pointer registry were only ever touched by one
thread. Two facts made a second Scheme thread unusable next to a libuv loop:

1. Chez's collector is stop-the-world and needs every *other* thread
   deactivated. A thread blocked inside a plain foreign `uv_run` stays *active*,
   so any other thread's `(collect)` errors (`cannot collect when multiple
   threads are active`) and allocation-triggered GC stalls ~100× — proven in
   `spike/threading/` (T2/T2b).
2. libuv handle/loop calls are not thread-safe, and the registry is a single
   process-global `eqv-hashtable`. An off-thread verb corrupts it.

The near-term driver is a real one: the chez-http-server worker-pool /
thread-per-core design, where worker threads must run alongside a loop thread
and hand completed work back to it.

## Decision

**1. `uv_run` and the trampolines it can invoke are `__collect_safe`.** A thread
blocked in `uv_run` is deactivated for the blocking poll, releasing Chez's
collect interlock so other threads collect freely. CSUG §4.3/4.8 makes this
all-or-nothing for the callables `uv_run` invokes, so thirteen of the fourteen
trampolines carry the attribute; `walk` alone stays plain because it fires only
from the synchronous `uv_walk`, never from `uv_run` (ADR-0008). Cost: ~60 ns per
callback, single-threaded.

**2. The binding is loop-thread-only, and that rule is *enforced*, not
documented.** Each loop record carries an owner-thread id:

- **set** to the creating thread at `make-uv-loop`, so setup before the first
  `uv-run` works;
- **transferred** to the calling thread at `uv-run` entry, under the existing
  `loop-running?` guard — so a loop may be created on one thread and handed to a
  dedicated loop thread. Concurrent `uv-run` is already refused, so the transfer
  is unambiguous.

`require-loop-thread` raises a structured `&uv-wrong-thread` (who / expected /
actual) when the caller is not the owner. It is wired into **one** central site,
`require-open-handle`, through which every operational handle verb already
passes — no per-verb sprinkling — and it runs before the open-state check and
before any registry mutation. `make-uv-async` calls it directly, because a
constructor mutates the registry before a handle exists to check.

**3. `uv-async-send!` is the one exempt verb.** `uv_async_send` is libuv's sole
thread-safe call, so it is the one way a worker thread hands work back to the
loop thread. It touches no registry state; it validates handle kind and open
state and calls `uv_async_send`. `uv_async` is the 14th locked trampoline
(ADR-0008). Sends coalesce (N sends may yield one wake), so the wake callback
drains a caller-side queue rather than assuming one item per send.

**4. No mutex on the registry.** D2 makes the registry safe by construction:
only the owning thread mutates it, enforced. A lock there would be false safety
— it would guard the hashtable while the libuv call it wraps is still unsafe
off-thread — so the affinity check, not a lock, is the mechanism.

**5. Opt-in, and free on a non-threaded Chez.** Identity uses `get-thread-id`
behind `current-thread-id`, which returns a constant on a non-threaded build, so
the affinity check is a tautology there and `uv-async-send!` still works.

> **Amended 2026-09-28 (issue #41): a threaded Chez is required.** Decision 5
> was never true.
>
> - Since v0.1, `(libuv private native)` has imported `make-mutex` and
>   `with-mutex`. Chez builds those only into threaded builds: they are
>   `[feature pthreads]` in its `s/primdata.ss`.
> - Measured on a `--nothreads` Chez 10.4.1: 14 of the 17 default suites
>   died at import with "missing import for make-mutex". The stress suite's
>   "skipped" branch could not run there either, because the suite imports
>   `fork-thread` itself.
> - The claim was reasoned, never run. Every Chez this project uses is
>   threaded, which is Chez 10's default.
>
> Rather than restore non-threaded support, the binding requires a threaded
> Chez and refuses any other by name. `(libuv private require-threaded)`
> raises its message while it is being expanded, so it must be imported
> ahead of every `(chezscheme)` import; Chez processes a library's imports
> in order, and a thread primitive imported first fails with the old
> message. Two checks hold this:
>
> - `tests/test-require-threaded.sps` holds the order on every `make test`.
>   It also expands the refusal's source with `(threaded?)` answering `#f`
>   and requires its message.
> - `make check-nothreads-docker` proves the refusal on a real `--nothreads`
>   Chez.
>
> `current-thread-id` is now `get-thread-id`, and the non-threaded branches
> are gone. For #33 this means the send fence is a plain mutex.

### Scope boundary

The enforced surface is **operational handle verbs** (everything entering through
`require-open-handle`) and **async construction** (`make-uv-async`). Deliberately
outside it, keeping their existing guards:

- **`uv-close!`** uses `require-handle` (not `require-open-handle`) because it is
  idempotent over the open→closing→closed protocol; its real mutation
  (deregister/free) happens in the close callback on the loop thread regardless.
- **Loop-level verbs** (`uv-stop!`, `uv-now`, `uv-loop-alive?`, the queries) and
  the other **constructors** (`make-uv-timer`/`-tcp`/`-pipe`/`-process`/
  `-signal`) are not routed through the central site. The worker-pool driver
  never touches these off the loop thread; extending the check to them is a
  clean follow-up if a future consumer needs it. `require-open-loop` is
  specifically *not* the check site, because `uv-run` calls it before
  transferring ownership — a check there would break the create-on-A/run-on-B
  handoff this ADR exists to enable.

> **Extended 2026-09-27 (issue #28).** `uv-update-time!` is the first
> loop-level verb inside the enforced surface: `require-open-loop`, then
> `require-loop-thread` — `make-uv-async`'s order — and both before the write.
> It *writes* `loop->time`, which the loop thread rewrites every iteration, so
> an off-thread call is a write-write race: a stale sample stored over a newer
> one moves the clock backwards, and on Windows whichever racing call sampled
> first can trip libuv's `new_time >= loop->time` assert (win/core.c). A new
> verb has no callers to break, so it starts checked. `uv-now` (a reader) and
> `uv-stop!` keep their standing above; changing a released verb's contract
> remains the follow-up this section names.

## Consequences

- A single-threaded program is unchanged except that the collect interlock is
  released around `uv_run` — a strict improvement — and every verb now confirms
  `owner == caller`, which is always true for it, so the check is invisible.
- A worker thread can allocate and collect freely while the loop thread blocks in
  `uv_run`, and post work back with `uv-async-send!`. An off-thread mistake on
  any other verb is a loud, named `&uv-wrong-thread` at the boundary instead of
  registry corruption.
- The async handle is one more registered handle: one `foreign-alloc` block,
  freed through the same close dispatcher, with its own allocation counter.
- Testing is split (ADR-0010 companion): deterministic affinity/async invariants
  on the default + memory gate (`tests/test-async.sps`), genuinely multi-threaded
  proofs off both gates (`tests/test-threading-stress.sps`).
- Not covered here, by design: making the binding thread-safe in general, a
  scheduler or thread pool (those live in the consumer, above the binding), and
  sharing a handle across threads (a handle belongs to its loop's thread for
  life).
