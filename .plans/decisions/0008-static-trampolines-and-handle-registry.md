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

The store-and-reraise error policy this trampoline design carries is
**contingent on Stage 0 spike Q2** — what a Scheme `raise` crossing libuv's C
stack frames actually does. If Q2's finding rules out raising from inside a
callback as unsafe, this ADR's error-delivery mechanism is the piece most
likely to need revision before it can move to `Accepted`.

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
- This ADR is explicitly the most spike-contingent of the ten: Stage 0's Q2
  finding must be recorded before its status can move past `Proposed`, and a
  negative finding changes the error-delivery mechanism described here, not
  merely adds a caveat to it.
