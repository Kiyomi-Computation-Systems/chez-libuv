# ADR-0008: Eight static, locked trampolines dispatch through a handle/request registry

- **Status:** Accepted (2026-08-18) — evidence: spike/FINDINGS.md Q1/Q2
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0007](0007-no-guardians-explicit-close.md)

## Context

Direct FFI ([ADR-0002](0002-direct-ffi-with-constants-only-shim.md)) means
libuv invokes Scheme code as a genuine callback: a `foreign-callable` entry
point that libuv calls from inside its own event loop, possibly while
`uv_run` is itself blocked deep in a C call stack. Chez's `lock-object`
prevents the garbage collector from moving a callable's underlying code
while a native caller might still be holding its address — necessary for any
`foreign-callable` a C library retains across an unbounded interval, which is
exactly libuv's contract for callbacks.

The number of locked objects has to be bounded and known, not one per handle
or per in-flight request: an unbounded number of `lock-object` calls,
growing with every TCP connection or timer the program ever creates, would
leave the collector permanently unable to move ever-more code as the program
runs longer, which is a resource leak by a different name.

## Decision

Exactly **eight** `foreign-callable`s exist — one per callback *type*, not
per callback *instance*: alloc, read, connection, write-done, close, timer,
shutdown, connect. Each is created and `lock-object`'d exactly once, at
process initialization, and never unlocked, for the life of the process.

> **Amended 2026-08-21 (v0.2 DNS, accepted 2026-08-21 — evidence: spike/dns/FINDINGS.md).**
> v0.2 grows the set from eight to **ten**: getaddrinfo
> (`(uptr int uptr) -> void`) and getnameinfo (`(uptr int uptr uptr) -> void`),
> libuv's two DNS completion signatures (uv.h:345-352) — neither matches any
> existing trampoline's arity, so neither can share one. The invariant this
> ADR protects was never the literal count; restated: **one locked trampoline
> per callback *type*, a constant small set per process** — the set moves only
> when libuv's callback typology does, never with handle or request volume.
> The two tests that deliberately froze the eight-name literal
> (tests/test-loop.sps:193-195, tests/test-native.sps:1124-1126) widen to the
> ten-name literal, watched to fail first. Unlike the original eight, whose
> dispatcher slots `handles.sls` installs in one batch, the two DNS slots are
> installed from `(libuv dns)`'s library body via
> `install-dispatch-procedure!` — exactly the late-added-callback-type case
> the seeding comment at handles.sls:885-892 anticipates — so a process that
> never imports `(libuv dns)` keeps the contained, raising stubs behind those
> two slots: the names exist and fail loudly, rather than silently doing
> nothing.

> **Amendment (v0.3, 2026-08-21): eleven trampolines.**
> The set grows ten → eleven: `exit`, for uv_exit_cb
> `(uv_process_t*, int64_t, int)` (vendor/libuv/include/uv.h:340) — a foreign
> type signature no existing trampoline has. The invariant is restated
> unchanged: one locked trampoline per callback TYPE, a constant small set
> per process; the set moves only when libuv's callback typology does. The
> two frozen literals (tests/test-loop.sps, tests/test-native.sps) were
> widened watched-to-fail first (see .plans/process-stage-2-mutation-log.md).
> The `exit` slot is installed from `(libuv process)`'s library body — the
> dns.sls late-install seam's second application.
>
> One v0.3 item could move the count again, and is recorded rather than
> pre-empted: if
> [ADR-0015](0015-spawn-copy-lifetime-and-failure-path.md)'s spawn-failure
> discriminator ships on `uv_walk`, its `uv_walk_cb` (uv.h:341) is a twelfth
> callback *type* and this count, design spec §5.2/§8, and both frozen
> literals move to twelve together. The invariant is indifferent to which way
> that lands — `uv_walk_cb` is libuv's typology, not a per-handle callable —
> which is what "the count was never the invariant" means.

Each trampoline's body is mechanical and uninstrumented: look up the
type-keyed dispatcher slot for that callback — one of the eight fixed names
(alloc, read, connection, write-done, close, timer, shutdown, connect), never
the firing pointer — and invoke it. The registry lookup that resolves the
firing `uptr` to its handle or request entry (design spec §5) happens one
step later, inside `handles.sls`' seam closure. The slots themselves carry
all callback policy — including the store-and-reraise error policy (design
spec §8) — and are installed exactly once by `handles.sls`, via
`install-callback-dispatchers!`; a second call to that procedure asserts, so
policy cannot be silently rebound after the fact. This keeps the one
FFI-reviewed file (`native.sls`) free of both dispatch logic and the registry
lookup itself.

> **Corrected 2026-08-18 (final review).** This paragraph originally read
> "look up the firing handle or request's `uptr` in the global registry ...
> and invoke a dispatcher slot found there," placing the registry lookup
> inside the trampoline body itself. The implementation's final shape has it
> the other way around: the trampoline body looks up a slot keyed by
> callback *type* and invokes it; the `uptr` → entry registry lookup happens
> one step later, inside `handles.sls`' seam closure (`seam-closure`, whose
> installed closure is what native.sls's dispatcher slot actually holds) —
> both to keep `native.sls` and `handles.sls` from importing each other
> circularly (native.sls's own comment beside `dispatcher-names` explains
> the cycle this avoids) and because the slot lookup has to be resolvable
> before any handle exists, while the registry lookup does not. Only this
> ADR's wording was wrong; the design spec (§4) carried the same error and is
> corrected alongside this.

The store-and-reraise error policy this trampoline design carries was
originally justified by the assumption that a Scheme `raise` cannot cross
libuv's C stack frames safely. **Stage 0 spike Q2 measured it, and that
assumption is false** (`spike/FINDINGS.md` Q2). The policy is retained; its
rationale is now the following three observations, not the refuted one:

1. **Propagation works.** A condition raised inside a `foreign-callable` does
   reach a `guard` established outside the blocking `uv_run` call, with its
   condition type and fields intact, and the loop object survives — a second
   `uv_run` on the same loop ran normally afterwards and teardown returned `0`
   at every step. This was confirmed to be a genuine continuation escape, not
   a handler running in place: `uv_run` never returned its `int`, and a
   `dynamic-wind` inside the callback ran its after-thunk without the body
   having completed.
2. **But the escape hands the caller an invisible cleanup obligation.** The
   abandoned iteration's *event* is not destroyed — measured directly: after
   escaping from a read callback (which libuv invokes from deep inside
   `uv__io_poll`), leaving every handle open and the read still started and
   then draining the loop **redelivered the pending `UV_EOF` in full**, and
   that late delivery then ran the EOF branch the escape had skipped. What is
   lost is not the event but the *work the callback was going to do*: at the
   moment of the escape that branch had not run, so the handles it would have
   closed stayed open, and **nothing re-runs the loop automatically**. A
   caller who reasonably treats the raise as terminal and proceeds straight to
   teardown gets `-16 (EBUSY)` back from `uv_loop_close` — also measured — and
   no indication of why. Raising from a timer callback (`uv__run_timers`, a
   much shallower frame) left nothing observable outstanding, with a single
   active handle. **A residue that varies with libuv's internal call depth is
   not something a caller can reason about**, because callers cannot see which
   frame was live.
3. **And an unguarded raise kills the process.** With no handler anywhere, the
   raise reaches Chez's default handler and terminates the process with exit
   status `255` — no teardown, no `uv_loop_close`, no `foreign-free`. This
   makes guarding every trampoline body mandatory *independently* of which
   error-delivery policy is chosen.

Store-and-reraise is therefore chosen for **determinism and for not leaving
the caller an obligation they cannot see**, not because propagation is
impossible and not because events are lost. Letting `uv_run` return through
its own C epilogue and re-raising from Scheme afterwards hands the caller a
loop in a defined state; that the iteration's already-queued callbacks all run
is a property of letting the iteration finish, not a Q2 measurement.

## Consequences

- The number of locked objects is constant and small regardless of how many
  handles or timers a program creates — the alternative's unbounded growth
  never materializes.
- The registry doubles as both the callback dispatch table and the GC root
  that keeps open handles reachable
  ([ADR-0007](0007-no-guardians-explicit-close.md)) — one data structure,
  two roles, rather than two structures that could drift out of sync.
- `native.sls` stays small and mechanical, which matters because it is the
  one file where a mistake in an FFI declaration fails silently until a
  callback actually fires with the wrong signature.
- This ADR was the most spike-contingent of the ten. Stage 0's Q2 finding is
  recorded in `spike/FINDINGS.md`; it left the **mechanism** described here
  unchanged and replaced its **rationale**, as set out under "Decision" above.
  The `escape` scenario measured there should not be read as a licence to let
  conditions unwind into libuv: it was sampled from two libuv frames, both of
  which happened to survive, and the binding deliberately does not depend on
  that holding for any other frame.
- Because an unguarded raise terminates the process outright, "every
  trampoline body is guarded" is a hard invariant rather than a stylistic
  preference, and `test-lifecycle` asserts the counters return to baseline
  after a callback raises — the check that would fail if a trampoline were
  ever left unguarded (AGENTS.md: prefer a check to a comment).
