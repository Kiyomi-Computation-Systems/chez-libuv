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

> **Amended 2026-10-05 (issue #45, item 5): twelve of thirteen.** libuv's
> alloc callback is now the shim's own C function
> ([ADR-0002](0002-direct-ffi-with-constants-only-shim.md) and
> [ADR-0008](0008-static-trampolines-and-handle-registry.md), amended the
> same day), so thirteen trampolines remain, and twelve carry the
> attribute. The shim's function needs none: it never enters Scheme, so
> libuv calls it while the loop thread stays deactivated.

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
>   there because its entry check refuses every return into a body that has
>   been left. A loop another thread is running keeps its mark, and the
>   teardown refuses it.
> - When the body leaves from inside a callback, that teardown can fail:
>   escaping one close callback strands the rest of libuv's batch, and
>   `uv_loop_close` answers `EBUSY`. v0.7.3 raised that in the middle of the
>   escape, and an engine suspended there ended in "no engine active" with
>   its continuation lost. Now the exit contains the failure and leaves the
>   loop marked running. The body runs once, so re-entry is refused even
>   though the loop is still open (PR #46's review).
>
> Dropping the `dynamic-wind` also saves 112 of the 128 B an idle `uv-run`
> allocated. `tests/test-loop.sps` holds the mark, the refusals and both
> `call-with-uv-loop` exits.

> **Amended 2026-10-07 (issue #78): the transfer is unambiguous only now.**
> "Concurrent `uv-run` is already refused" was false from v0.6.0 on. The
> refusal was a plain read of the mark, and the mark was set by a later
> plain write, with the mode, the pointer, the deferred list and the owner
> in between. Two threads that called `uv-run` on one loop both passed the
> read and ran `uv_run` on one `uv_loop_t`. Within seconds, two of the
> loop's timer callbacks ran at once, `invalid memory reference` was raised
> out of `uv-run` and left the loop marked running for good, or both
> threads spun in libuv's timer heap. `uv-loop-close!` and
> `uv-loop-teardown!` read the mark the same way, so either could free the
> loop, or close its handles, under a run that had just begun. One thread
> was enough, too: a `uv-run` an engine split between its read and its
> write let the same thread close the loop, and the resumed run used the
> freed block.
>
> - **The claim.** A run, a close and each step of a teardown take the
>   loop's claim before they call libuv on it (`claim-loop!` in `(libuv
>   private handles)`) and give it back when they are done. The mark is a
>   box per loop holding the claiming thread's id, taken by `box-cas!`, so
>   no two calls on any threads hold it at once. The take, the open check
>   and the owner transfer are one interrupt-free step, so no engine of the
>   claiming thread comes between them, and a refused claim changes
>   nothing. A closed loop is answered before any claim: it never reopens.
> - **No lock.** The registry's lock would have served too, but the claim
>   needs nothing a lock gives beyond one compare-and-set, and a lock every
>   loop's thread shares would put each run of every loop behind it. A box
>   per loop costs 16 B a loop and no wait.
> - **Order.** The open check comes after the take. A close sets the loop
>   closed while it holds the claim, so a run that claims after the close
>   finds it closed, never a freed pointer. An acquire fence after the take
>   and a release fence before the clear order libuv's own state, written
>   by one thread's `uv_run`, before the next holder reads it: on arm64
>   `box-cas!` is a bare exclusive load and store with no ordering of its
>   own, and fails now and then with the box unchanged, so a failed take
>   is a refusal only when the mark is really held.
> - **Close and teardown claim too** (the issue left this to decide). A
>   close is one interrupt-free step: claim, `uv_loop_close`, the record
>   closed and freed, release. A teardown is three kinds of step, each
>   claimed only while it calls libuv: closing every handle, one
>   interrupt-free step; each run of the drain, claimed as `uv-run` claims
>   (the same `run-step!`); and the close. A close does not take the loop
>   over, so a close refused `'EBUSY` on another thread leaves the loop with
>   its owner; a teardown takes it over at each run, as its drain's
>   `uv-run` always did.
> - **Why the teardown releases between steps.** Held across the whole
>   teardown, the claim made an engine dropped anywhere in it strand the
>   loop for good: every later call refused, the loop and its descriptors
>   kept. A review of the first version measured that at 2,997 of 3,000
>   drop points of a teardown, against 624 on v0.7.3, where only a drop
>   inside the drain's `uv_run` left the loop marked. Now a dropped close
>   never strands its loop, and a dropped teardown does only inside a run
>   of its drain, at no more expiries than a dropped `uv-run`. The price:
>   between steps another call can get in. A teardown that then finds the
>   loop closed returns, and one that finds it claimed is refused
>   `'loop-running` with its handles closing, to be called again; no two
>   calls are ever inside libuv at once.
> - **`call-with-uv-loop`'s exit.** It asked "marked, and owned by this
>   thread" to find a claim its own thread left. A close claims without
>   moving the owner, and a run takes the mark before it stores the owner,
>   so another thread's claim of either kind passed that test, and the exit
>   tore the loop down under it (SIGABRT in 3 of 3 runs of the review's
>   probe). The exit now asks whether the mark names its own thread, and
>   hands that claim straight to the teardown: clearing it first let
>   another thread's run in, and the exit then wrote its mark over that
>   run's claim, leaving the loop claimed with no run in it.
> - **Every exit gives the claim back**, a refusal included: libuv's
>   `'EBUSY`, a callback's error, the drain bound. Nothing in a claimed step
>   raises; each answers a status and the verb raises after the release,
>   so no `guard` sits around a teardown (one cost about 400 B a teardown,
>   and gave the claim back over a fault raised out of `uv_run`). A callback
>   that never returns (an engine's suspension, an escaping continuation)
>   still leaves the claim held, as #45 decided above. The pending callback
>   error is taken by the claim's holder only, an assertion: once the claim
>   is given back, another thread's run can set one of its own.
> - **Left as it was:** a drop between a run's claim and `uv_run`, or
>   between `uv_run`'s return and the release, leaves the loop claimed, as
>   the series' last part already records (decision 3's amendment).
>
> `tests/test-loop-claim.sps` races two threads on one loop for each verb,
> with bounded waits so a broken build fails by name instead of hanging,
> sweeps engine splits and drops of each verb, holds every way out of a
> claim, and holds the exit against another thread's claim. Rule 7 of
> `tests/test-source-rules.sps` keeps `set-loop-holder!`, which sets the
> mark outright, out of `src/`. Evidence and mutations:
> `.plans/loop-claim-mutation-log.md`.

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
> `.plans/async-send-fence-mutation-log.md`. Decision 4 stands (until #70;
> see its amendment): this lock guards one handle's lifetime across the one
> call libuv makes thread-safe, not the registry. The cost, on libuv's no-syscall fast path: about 30 ns a
> send on macOS arm64, up from 8, with no allocation. Senders sharing one
> handle take turns: about 90 ns a send with four.

> **Amended 2026-10-06 (found reviewing #49): every stream verb is one
> step.** The fence's discipline was never only about threads. An engine
> on the loop thread splits a verb just as another thread does, and every
> verb that checks a handle and then calls libuv on it was split by one:
>
> - **A close freed the stream between the check and the call.** A sweep
>   suspended each verb at every point, closed the stream, stepped the
>   loop until the close freed it, and resumed. Under Guard Malloc,
>   `uv-write!` faulted at fuel 12–30, `uv-write*!` at 12–37,
>   `uv-shutdown!` at 10–21 and `uv-read-start!` at 16–17. `uv-read-stop!`
>   and `uv-stream-write-queue-size` faulted at fuel 10, between reading
>   the pointer and the call. When a new connection was given the freed
>   address before the resume, as it was on every macOS run, `uv-write!`
>   reported success and its bytes reached the new connection's peer.
>   `uv-read-start!` resumed after the close also put a read buffer into a
>   record its close had already cleaned up, and nothing freed it. (#48,
>   merged meanwhile, made the buffer's install a step that refuses a
>   closed stream; its start still read the pointer outside any step.)
> - **A dropped engine stranded what the verb held.** A scheduler that
>   drops a task, as a timeout does, runs nothing after the suspension: no
>   `guard`, and no `dynamic-wind` exit (that runs at the suspension
>   itself, before anyone knows whether the engine will be resumed). A
>   `uv-write!` dropped between its allocation and libuv lost the block,
>   or left a request registered and counted that libuv never saw and
>   teardown never swept, since `registry-snapshot-for-loop` collects
>   handles only.
>
> Each stream verb (`uv-write!`, `uv-write*!`, `uv-shutdown!`,
> `uv-read-start!`, `uv-read-stop!`, `uv-stream-write-queue-size`) now
> validates its arguments, then makes one interrupt-free step: the open
> check again (`open-handle-ptr`), the pointer, a second check of what it
> reads of the caller's data (the spans, the read buffer's size), the
> allocation, the registration, the count, and the native call. The step
> answers a status, and the verb raises afterwards (`step-refusal`), with
> the condition the checks outside a step raise: `&uv-handle-closed` for a
> stream closed meanwhile. So an engine suspends or drops a verb only
> before its step, when it holds nothing, or after it, when libuv holds
> what it was given and its completion frees it. `one-step` in
> `(libuv private handles)` is the step; `begin-close!` is now written with
> it too, and so is #48's `install-read-buffer!`, which the read start's
> step makes. The rules are the fence's:
>
> - **A bare `disable-interrupts`/`enable-interrupts` pair.**
>   `with-interrupts-disabled` is a `dynamic-wind`: 96 B a step around a
>   copy (#49's measurement), and its exit thunk runs where an engine can
>   still suspend.
> - **Nothing raises inside.** Every call a step makes is total for its
>   arguments. `foreign-alloc` raises when malloc fails, so the binding's
>   blocks now come from the shim: `chez_uv_alloc` (calloc) answers NULL,
>   and `alloc-block`, `free-block!` and `copy-in-unchecked!` answer or
>   ignore what they cannot use. `registry-add!`, the registry's one write
>   site, answers its refusals, and `registry-register!` raises them.
>   `tests/test-stream.sps` checks after each run that interrupts are
>   enabled, so a raise inside a step fails a row by name.
>
> Because the span is checked again inside the step, before the block is
> allocated, #49's leak cannot arise in the write verbs: a span the
> payload no longer covers is refused with nothing allocated.
> `try-copy-in!` remains as `copy-in!`'s base.
>
> The debug shim also counts every block it allocates (`'block` in
> `live-counts`). So a block a verb loses fails a row in plain `make test`,
> and not only under Valgrind, and every suite's closing all-zero check
> now covers blocks too.
>
> - **Measured after:** every suspended run of every sweep is refused
>   before its step, every dropped one leaves the registry, every counter
>   and the blocks as it found them, and a new connection at the freed
>   address receives nothing. Allocation per call fell from 240 B to
>   144 B for `uv-write!` and from 304 B to 208 B for a one-segment
>   `uv-write*!`; `uv-shutdown!` stays at 128 B. Evidence and mutations:
>   `.plans/stream-step-mutation-log.md`.
> - **Trade-offs:** a fault in a native call inside a step leaves
>   interrupts disabled, as `begin-close!` always has. And the thread
>   stays active for the whole step, so another thread's collection waits
>   for all of it, where it waited for each foreign call in it before. On
>   macOS loopback that wait is dominated by `uv_write`'s own copy into the
>   socket, and the call takes as long as before (0.2–0.9 ms for 1 MiB,
>   2.4–4.4 ms for 4 MiB). The shim gained exports, so an upgrade
>   needs `make build`; an old shim is refused with `&uv-shim-unavailable`.
> - **Not yet done:** measured on the same base, the same splits and drops
>   reach the other verbs, each to be made one step in turn.
>   - The constructors: a block lost, or teardown failing with `EBUSY` for
>     good once the handle is initialised and not yet registered. For
>     `make-uv-async` the teardown hangs, and `make-uv-loop` also leaks its
>     backend fd. (Each is one step since the next amendment.)
>   - `uv-tcp-connect!`, `uv-getaddrinfo!` and `uv-getnameinfo!`: a block
>     lost, or a request registered and never submitted.
>   - `uv-spawn!`: one or two blocks lost, or `EBUSY`.
>     - Later on 2026-10-06 its splits were closed, and the `EBUSY` with
>       them: the step that spawns checks the stdio handles and the loop
>       again, and marks the pipes, registers the process or cleans up
>       inside it (ADR-0015, the amendment to decision 5). A drop between
>       its allocations and that step still loses both blocks.
>     - Its drops were closed the same day (#63): the step allocates the
>       process handle and the options block, and builds the block, so
>       `uv-spawn!` holds nothing before it (ADR-0015, the amendment to
>       decision 1). `tests/test-process.sps`'s drop sweeps hold it.
>     - Found reviewing #63 (this split is fixed below): `uv-process-kill!` and
>       `uv-process-pid` split between the pointer and the call, and a
>       split kill signalled another process at the freed handle's address
>       (#71). Separately, decision 4 held per loop only: the registry is
>       one table for every loop, and two loops run on two threads
>       corrupted it (#70, decision 4's amendment).
>   - The scratch verbs (bind, the address and port queries, the buffer
>     sizes): one or two blocks lost.
>   - Every other handle verb, and `uv-run`, `uv-stop!`, `uv-now`,
>     `uv-loop-alive?` and `uv-update-time!` after a teardown: one or two
>     fuel values, between reading the pointer and the call.

> **Amended 2026-10-06 (the series' second part): every constructor is
> one step.** Measured on main (eb5b719), with the sweeps now in
> `tests/test-constructors.sps`, over `make-uv-timer`, `-tcp`, `-pipe`,
> `-signal` and `-async`, `uv-accept!`, which makes the client it accepts
> into, `make-uv-loop` and `call-with-uv-loop`:
>
> - **A teardown between the check and the init.** A sweep suspended each
>   constructor at every point, tore its loop down, and resumed it. Under
>   Guard Malloc each handle constructor initialised its handle on the
>   freed `uv_loop_t` at one fuel, two for `make-uv-async`. `make-uv-tcp`
>   and `make-uv-pipe` also wrote the stream's descriptor into a handle
>   block the teardown had freed, at another. Ten to fourteen fuels each
>   were refused as `null-loop-pointer` rather than `&uv-handle-closed`.
>   A teardown between the init and the registration could not close the
>   handle: `uv_loop_close` failed with `EBUSY` for good at three to five
>   fuels, and for `make-uv-async`, which keeps its loop alive, the
>   teardown's drain would never have returned.
> - **`uv-accept!` and its server.** Suspended, then resumed after its
>   server was closed and freed, it called `uv_accept` on the freed server
>   at fuel 42, and raised `null-handle-pointer` at 33 earlier fuels.
>   Resumed while the close was pending, it raised libuv's `EAGAIN`.
> - **Dropped.** Each handle constructor lost its block at six or seven
>   fuels, left its handle initialised and unregistered at three to five
>   (the same `EBUSY`, or the hang), and left a counter at −1 at one.
>   `make-uv-loop` lost its block, or the loop with its two descriptors.
>   `call-with-uv-loop` made its loop before entering its `dynamic-wind`,
>   and at two fuels in between an engine dropped the whole loop.
> - **The init lock.** Every constructor starts at `ensure-native-loaded!`,
>   which took its lock with `with-mutex` on every call. Dropped in its
>   exit thunk, after the winder is gone and before the release, it left
>   the lock held for good: fuel 11–14, one in each constructor. The lock
>   is recursive, so this thread carried on, and any other thread's next
>   constructor would have waited on it forever.
> - **The handoff.** `make-uv-async` is loop-thread-only, checked before
>   any allocation. Suspended after the check while the loop was handed to
>   another thread, it made the async anyway, for a loop this thread no
>   longer owned.
>
> Each constructor now makes its handle in one interrupt-free step,
> `try-construct-handle` in `(libuv private handles)`: the loop's open
> check again (`open-loop-ptr`), the block, the record, its registration,
> libuv's init, a stream's descriptor, and the count, and for
> `make-uv-async` the loop's owner. The handle is registered before the
> init (`register-then-init!`), so a refused registration frees a block
> libuv never saw and a failed init unregisters it; a step refused leaves
> nothing behind, and `step-refusal` raises what stood in the way, a
> closed loop as `&uv-handle-closed`. `uv-accept!` checks its server and
> calls `uv_accept` in the same step, the client's construction nested in
> it. `make-uv-loop` makes the same step for a loop, `try-construct-loop`,
> and `call-with-uv-loop` now makes its loop inside its body, handed the
> loop inside the step, so wherever an engine expires from there on its
> exit finds the loop to tear down. `ensure-native-loaded!` takes and
> releases its lock with interrupts disabled, the send fence's discipline:
> no engine expires and no collection stops a thread holding it, so a
> thread that waits on it, waiting with interrupts disabled too, waits only
> for a holder that is running. Unlike the fence's body, the init can
> raise, and `with-interrupts-disabled`'s `dynamic-wind` unwinds it.
>
> - **Measured after:** every split run is refused before its step, every
>   dropped run leaves the registry, the counters, the blocks, the
>   descriptors and the init lock as it found them, and no run was
>   suspended after its step. Allocation per call fell by 96–112 B, since
>   no `guard` wraps the init any more: `make-uv-timer` 608 → 496 B,
>   `make-uv-tcp` 656 → 560, `make-uv-async` 688 → 592, `make-uv-loop`
>   592 → 480. Evidence and mutations:
>   `.plans/constructor-step-mutation-log.md`.
> - **Found, not done:**
>   - An engine dropped inside `call-with-uv-loop`'s own teardown, on the
>     way out of the body, leaves the loop open. If the drop lands in
>     `uv-run` between setting the running mark and clearing it, it leaves
>     the loop marked running, which no verb then touches. Both belong to
>     the loop verbs, the series' last part.
>   - The stream verbs' steps (#53) re-check the handle but not the loop's
>     owner. This change re-checks the owner for `make-uv-async` only, the
>     one constructor inside the enforced surface.

> **Amended 2026-10-07 (#71): `uv-process-kill!` and `uv-process-pid` are
> one step.** Each checked that its process was open, read the handle's
> pointer and called libuv in separate steps. Measured on main (bfd2bbe),
> with the sweeps now in `tests/test-process-steps.sps`, on macOS and on
> glibc 2.39:
>
> - **A new process at the freed address.** Suspended after the check while
>   a close freed the handle and a new process's handle took its address,
>   `uv-process-kill!` resumed, sent the NEW process its SIGTERM and
>   returned normally, and `uv-process-pid` answered the new process's pid.
>   With a signal name, the kill was refused at three fuels before that as
>   `null-handle-pointer` rather than `&uv-handle-closed`.
> - **A freed block.** Resumed on the freed block itself, each read it: the
>   kill, sent signal 0 by the sweep, returned normally, and the pid read 0
>   on macOS and the old pid on glibc. Whatever pid that block holds is
>   what a stale kill signals, and 0 there is `kill(0, sig)`, the caller's
>   own process group, so the sweeps send signal 0 wherever a stale call
>   could reach a freed block.
>
> Each verb now checks its process again (`open-handle-ptr`), reads the
> pointer and calls libuv in one `one-step`, and raises after the step
> (`step-refusal`), as the stream verbs do. A process closed while the verb
> is suspended is refused with `&uv-handle-closed`, unless the verb had
> made its call before the suspension. Neither verb has a trap check after
> its step, so in the sweeps no run was suspended there; a collection
> another thread requests can still be taken where the step ends (#68).
>
> - **Measured after:** every suspended run is refused, the new process
>   comes through untouched, and every dropped run leaves the counters as
>   it found them. Neither verb allocates, before or after: 0 B a call.
>   Evidence and mutations: `.plans/process-verb-steps-mutation-log.md`.
> - **The new process's handle.** A spawn made after the close took the
>   freed address by itself in 24 to 30 of 30 runs on macOS, and in none
>   of 30 on glibc 2.36 or 2.39. So the reuse sweep places a copy of the
>   new process's handle at the freed address, and resumes a run only once
>   libuv reads the new process's pid there.

**4. No mutex on the registry.** D2 makes the registry safe by construction:
only the owning thread mutates it, enforced. A lock there would be false safety
— it would guard the hashtable while the libuv call it wraps is still unsafe
off-thread — so the affinity check, not a lock, is the mechanism.

> **Amended 2026-10-07 (issue #70): the registry has one lock after all.**
> Decision 4 held per loop only. Affinity keeps each loop's handles on one
> thread, but the registry is one table for every loop. So two loops run
> on two threads at once, the thread-per-core design this ADR names as its
> driver, wrote it from both threads, and Chez's hashtables have no lock of
> their own. Two threads making and closing timers on loops of their own
> corrupted it in 4 of 4 runs: a constructor raised
> `pointer-already-registered` or `invalid memory reference`, or a teardown
> read an entry that was not one. Three more pieces of process-wide state
> were shared the same way:
>
> - the cell `handle-in-loop-queue?` collects `uv_walk`'s pointers in,
>   which decides how a failed spawn is cleaned up (ADR-0015). Another
>   thread's walk reset it mid-read, so a handle in its loop's queue was
>   reported out of it: up to 202 of 20,000 checks;
> - the orphan event list, which lost 29–50% of the events two threads
>   recorded;
> - the debug shim's allocation counters, whose `+=` lost updates.
>
> **What changed.**
>
> - Every use of the registry and the orphan list holds one lock,
>   `registry-lock`, through `with-registry-lock` in
>   `(libuv private handles)`. That covers the constructors' and requests'
>   registrations, every callback seam's lookup, the close dispatcher's and
>   the completions' deregistrations, a teardown's snapshot, which also
>   finds its DNS requests to cancel, and the readers.
> - The lock has the send fence's shape (decision 3's amendment for #33),
>   and both now use one macro, `with-step-lock`. It is taken and released
>   only with interrupts disabled, so no engine is suspended, and no
>   collection stops a thread, while it holds the lock. A thread that finds
>   it taken waits inside the same interrupt-free step, for a holder
>   running a table operation or two, which wait on nothing, or a copy of
>   the whole table (the trade-off below). The bodies raise nothing, and
>   their callers raise after; rule 6 holds every body to table operations
>   and `cons`. `with-step-lock` hands back however many values its body
>   answers.
> - The walk cell is a thread parameter: `uv_walk` calls back on the thread
>   that walks, before it returns.
> - The debug shim's counters are updated with atomic adds, in relaxed
>   order.
>
> Decision 4's argument still holds for what it was about. A lock cannot
> make an off-thread verb safe, since the libuv call it wraps still races
> the loop's own thread, so affinity stays the mechanism for each loop's
> handles. The lock guards only the state every loop shares.
>
> **The trade-off: one lock, or a table per loop.** Both fixed every race
> above. The figures are macOS arm64 and Chez 10.4.1. The timer rows use
> the release shim with collections held off, and are the medians of five
> alternated rounds. The round trip is the median of three rounds of each
> thread's best of five, and the teardown the median of eleven.
>
> | | One lock (chosen) | A table per loop |
> |---|---|---|
> | One thread | +27 ns a constructor, +38 ns a callback, +70 ns a close (two uses); 0 B | within 12 ns of the unlocked registry |
> | Four threads, only making, firing and closing timers | 381, 2,714 and 3,420 ns | 170, 1,651 and 1,608 ns |
> | A loopback round trip | 75.7 µs at one thread (76.3 µs without a lock); 120.1 µs at four; 231 µs at eight, its runs 223–233 µs | 76.9, 120.1 and 216 µs, its runs at eight 213–232 µs |
> | A teardown, or `uv-loop-live-handles`, with other loops' entries registered | copies every loop's entries while it holds the lock: 0.66 ms a call at 100,000 entries, 13 ms at 1,000,000, most of it the copy | copies its own loop's |
> | Change | `handles.sls` alone: every registry signature and every suite as before | `handles`, `loop`, `stream`, `process`, `dns` and `tcp`; request records gain a loop; test helpers in about 8 suites |
>
> A table per loop needs no lock of its own, and a seam can reach its
> loop's table from its own pointer: a handle's `loop` field, a write's,
> connect's or shutdown's handle, a DNS request's `loop`. But the seam
> then needs the binding's loop for that `uv_loop_t`, from a table of every
> loop that every thread shares and every callback reads, and that
> `make-uv-loop` and `uv-loop-close!` change from any thread: a lock again,
> or a lock-free publication of it. The prototype measured here found the
> loop another way, through the loop its thread was running, which
> `uv-run` tracked by hand across engine suspensions with no
> `dynamic-wind` (#45's amendment to decision 2). Process-wide views such
> as `registry-count` would need a shared list of live loops anyway, and
> the change reaches six libraries. Neither design makes a constructor
> called from the wrong thread safe: its libuv init races the loop's own
> thread whatever guards the table (decision 4). An owner check in every
> constructor would (#79).
>
> The lock shows only where several threads use the registry without
> pause, or where a teardown copies a large table. In a loopback round
> trip each thread spends most of its time waiting on the kernel, and the
> lock never queued; at eight threads the round trip took 7% longer than
> with a table per loop, within the runs' spread. Should a workload show
> contention, the next step keeps every lookup free of the running loop:
> several tables, chosen by pointer, each with a lock of its own. Should
> a teardown's copy show, an index of each loop's entries, kept under the
> same lock, lets it copy its own.
>
> **Held by** `tests/test-loop-threads.sps`, whose rows:
>
> - race two loops' threads over timers, walks, orphan events and every
>   debug counter, with a precondition that each thread saw the other
>   move. A thread past its rounds waits on the other's progress, never on
>   a count of its own, so no schedule fails a correct build;
> - sweep engines over the calls whose way to the lock crosses a trap
>   check, a timer's firing and a close, asking another thread at each
>   expiry whether the lock is free;
> - require a refused registration or deregistration to reach the caller's
>   handler with the lock free, and `with-step-lock` to hand back two
>   values or none with its lock free.
>
> And by rule 6 of `tests/test-source-rules.sps`. It lists each
> process-wide variable in `src/` with how threads share it: what a
> library's top level defines and then assigns, changes in place, or makes
> mutable, and each static in the C shim. A new one fails until it is
> listed, and each word is checked against the source. Every use of the
> registry and the orphan list must sit inside `with-registry-lock`, every
> body there may call only table operations and `cons`, `registry-lock` is
> named nowhere else in `src/`, and the shim's counters change only
> through `count_add`. Evidence and mutations:
> `.plans/registry-lock-mutation-log.md`.

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
