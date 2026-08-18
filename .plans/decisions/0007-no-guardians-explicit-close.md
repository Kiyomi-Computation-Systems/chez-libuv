# ADR-0007: No guardians — `uv_close` is always explicit, never GC-driven

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0008](0008-static-trampolines-and-handle-registry.md)

## Context

Chez's guardians make it possible to have a finalizer run `uv_close`
automatically when a handle record becomes otherwise unreachable — a
seemingly convenient safety net against callers who forget to close what
they open.

`uv_close` is not a synchronous free, though: it is **asynchronous** (it
schedules `close_cb` for a later loop iteration, rather than freeing
anything immediately) and **loop-affine** (the call, and the callback it
schedules, must happen on the thread running that handle's `uv_loop`). A
guardian fires at garbage-collection time — a moment with no guaranteed
relationship to loop iteration, no guarantee the owning loop is even still
running, and no guarantee the collecting thread is the loop's thread. Driving
an asynchronous, thread-affine protocol from a nondeterministically-timed GC
callback is not a safety net; it is a second, harder-to-reason-about failure
mode layered on top of the one it was meant to prevent.

## Decision

No guardian anywhere touches a handle or a request. `uv-close!` is the only
path that ever begins the close protocol (design spec §5), always invoked
explicitly by the caller — or, at loop teardown, by `uv-loop-teardown!`
closing every handle the registry still knows about for that loop.

The registry (design spec §5, [ADR-0008](0008-static-trampolines-and-handle-registry.md))
is what keeps an open handle reachable for as long as it is open, independent
of whatever the caller's own references to it look like — so a handle the
Scheme program appears to have "dropped" stays alive and functioning until
it is actually closed, and a handle nobody ever closes leaks *deterministically
and visibly*, via the debug counters
([ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md)) and Valgrind,
rather than being silently swept up by GC at some unpredictable later point.

## Consequences

- Every caller must call `uv-close!` on every handle it opens;
  `call-with-uv-loop` and `uv-loop-teardown!` cover the loop-exit case, but
  nothing covers a caller who leaks a handle mid-run.
- A forgotten close is a visible, countable leak rather than a silent,
  GC-timed close that could otherwise run on the wrong thread or after the
  owning loop has already stopped.
- `test-lifecycle` asserts counters balance after an explicit close and
  explicitly rejects the idea of a handle closing itself mid-test through any
  GC-triggered path.
- This is a documented API contract, not an implementation detail: callers
  coming from garbage-collected languages with finalizer-based cleanup
  conventions must be told explicitly that this binding has none.
