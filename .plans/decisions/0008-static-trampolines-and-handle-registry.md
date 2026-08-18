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

Each trampoline's body is mechanical and uninstrumented: look up the firing
handle or request's `uptr` in the global registry (design spec §5) and
invoke a dispatcher slot found there. The slots themselves carry all
callback policy — including the store-and-reraise error policy (design spec
§8) — and are installed exactly once by `handles.sls`, via
`install-callback-dispatchers!`; a second call to that procedure asserts, so
policy cannot be silently rebound after the fact. This keeps the one
FFI-reviewed file (`native.sls`) free of dispatch logic entirely.

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
2. **But the escape silently loses events.** Whatever the abandoned libuv
   frame had left to do in that loop iteration simply does not happen, and
   nothing reports it. Observed: raising from inside a read callback — which
   libuv invokes from deep inside `uv__io_poll` — permanently discarded a
   pending `UV_EOF`, which never arrived even after a full subsequent drain.
   Raising from a timer callback (`uv__run_timers`, a much shallower frame)
   lost nothing. **A failure mode that varies with libuv's internal call depth
   is not something a caller can reason about**, and losing an EOF silently is
   indistinguishable, from Scheme, from a peer that simply never closed.
3. **And an unguarded raise kills the process.** With no handler anywhere, the
   raise reaches Chez's default handler and terminates the process with exit
   status `255` — no teardown, no `uv_loop_close`, no `foreign-free`. This
   makes guarding every trampoline body mandatory *independently* of which
   error-delivery policy is chosen.

Store-and-reraise is therefore chosen for **determinism and event-loss
prevention**, not because propagation is impossible. Letting `uv_run` return
through its own C epilogue and re-raising from Scheme afterwards hands the
caller a loop in a defined state, with every callback libuv had queued for
that iteration already delivered.

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
