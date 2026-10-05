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

> **Amended 2026-10-05 (issue #45): the running mark lasts as long as
> uv_run's frame.** The transfer still happens at `uv-run` entry, but the
> `dynamic-wind` that set and cleared `loop-running` is gone.
>
> - It cleared the mark whenever control left `uv-run`. An engine that runs
>   out of fuel inside a callback leaves `uv-run` while uv_run's frame stays
>   live in the middle of an iteration, to be resumed. During that
>   suspension every verb accepted the loop. On v0.7.3 a `uv-loop-teardown!`
>   then freed it, and resuming the engine died with "invalid memory
>   reference".
> - Now the mark is set before the call and cleared when uv_run returns, so
>   the verbs that run, close or tear down the loop refuse it while an
>   engine is suspended in one of its callbacks. No raise unwinds through
>   the frame, because the seams contain them all.
> - A continuation that escapes a callback abandons the frame for good, and
>   the loop stays marked running. Re-running it was never sound: escaping a
>   close callback strands the rest of libuv's batch of closes, and teardown
>   then fails with `'EBUSY`.
> - `call-with-uv-loop` still tears its own loop down on the way out. It
>   clears the mark first, but only one this thread left. That is safe
>   there because its entry check refuses every return into the body once
>   the loop is gone. A loop another thread is running keeps its mark, and
>   the teardown refuses it.
>
> Dropping the `dynamic-wind` also saves 112 of the 128 B an idle `uv-run`
> allocated. `tests/test-loop.sps` holds the mark, the refusals and both
> `call-with-uv-loop` exits.

**3. `uv-async-send!` is the one exempt verb.** `uv_async_send` is libuv's sole
thread-safe call, so it is the one way a worker thread hands work back to the
loop thread. It touches no registry state; it validates handle kind and open
state and calls `uv_async_send`. `uv_async` is the 14th locked trampoline
(ADR-0008). Sends coalesce (N sends may yield one wake), so the wake callback
drains a caller-side queue rather than assuming one item per send.

> **Amended 2026-09-28 (issue #33): the exempt verb is fenced.** As
> decided, `uv-async-send!` checked the handle's state, read its pointer, then
> called `uv_async_send`. A close on the loop thread could free the block in
> between: libuv's own guard, `uv__async_spin`, waits only for a sender
> already inside `uv_async_send`. Until now only a caller convention
> prevented that (docs/api.md, #30 and #32).
>
> Each async handle now carries a send fence, a mutex that `uv-async-send!`
> and `uv-close!` both take (`with-send-fence` in `(libuv private handles)`).
> The send's open check and native call run inside it, and so does the
> close's whole step: the open check, the move to closing, and `uv_close`. So
> a send either completes before a close begins, or is refused with
> `&uv-handle-closed` without touching the handle. That holds from any thread
> and inside engines. Two rules make the mutex a fence:
>
> - **It is taken and released only with interrupts disabled.** So no engine
>   is ever suspended holding it, and no collection ever stops a thread that
>   holds it. A thread that finds it taken waits inside the same
>   interrupt-free step. It stays active while it waits, but the holder is
>   running a step that never waits, so the wait is short and no collection
>   can be waiting on the holder. The first shape reviewed, `with-mutex`
>   around `with-interrupts-disabled`, broke this rule. `with-mutex` releases
>   in a `dynamic-wind` exit thunk, at a point where an engine can still be
>   suspended. An engine dropped there kept the fence for good, and a
>   collection could park the holder while a caller with interrupts disabled
>   waited on it, deadlocking the process. PR #43's review measured both.
> - **Nothing raises inside.** The steps check the state and the pointer,
>   answer a status, and the caller raises after the release. A
>   `with-exception-handler` handler runs in the raise's dynamic extent, so a
>   refusal raised inside would reach it with the fence held.
>
> `tests/test-async-fence.sps` holds both. Its engine sweeps probe the fence
> from another thread at every point where a send or a close can be
> suspended, and other rows make a real sender and a real closer wait on a
> held fence, and check its release on every way out. The mutations, the
> deadlock reproducers and the widened-window runs are in
> `.plans/async-send-fence-mutation-log.md`. Decision 4 stands: this lock
> guards one handle's lifetime across the one call libuv makes thread-safe,
> not the registry. The cost, on libuv's no-syscall fast path: about 30 ns a
> send on macOS arm64, up from 8, with no allocation. Senders sharing one
> handle take turns: about 90 ns a send with four.

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
