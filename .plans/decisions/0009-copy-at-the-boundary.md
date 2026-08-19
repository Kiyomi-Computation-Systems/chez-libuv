# ADR-0009: Copy at the FFI boundary; defer zero-copy without foreclosing it

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0002](0002-direct-ffi-with-constants-only-shim.md)

## Context

Passing Scheme bytevector storage directly to libuv, or vice versa, would
avoid a copy on every read and write — but it runs directly into how Chez's
collector and libuv's async model interact. The Scheme heap can move
bytevectors, and libuv holds a pointer for an unbounded, caller-invisible
duration between issuing an asynchronous operation and its completion
callback: from `uv_write` until `write-cb` fires, or for the entire lifetime
of a handle's read buffer. Making the collector aware of every such in-flight
pointer is possible — `lock-object` per operation — but adds real overhead
and bookkeeping that has no justification before it is known to matter for
this binding's actual workloads.

## Decision

Every buffer crossing the FFI boundary is copied, in both directions.

**Reads:** one reusable `foreign-alloc`'d buffer per handle (design spec
§6), delivered to `on-data` as a freshly copied bytevector shaped
`(bv start end)` — a span rather than a bare bytevector, specifically so a
future zero-copy variant can hand back a sub-range of a larger buffer without
changing the call shape callers already depend on.

**Writes:** the caller's bytevector is copied into one `foreign-alloc`'d
block built by `uv-write!` (design spec §7); the caller's own bytevector is
free to be reclaimed the instant `uv-write!` returns, and the block is freed
in the write-done dispatcher **before** `on-complete` runs.

> **Corrected 2026-08-18 (Stage 4).** This paragraph originally read "after
> `on-complete` runs", contradicting design spec §7's "pops the request entry
> and frees the block **before** invoking `(on-complete err)`". The spec is
> the authority and is what the implementation and
> `.plans/stage-4-mutation-log.md` (mutation 3) enforce: freeing first is what
> bounds memory on a stream with many queued writes by the code rather than by
> how long each callback happens to take. Only this ADR's wording was wrong.

Vectored (scatter-gather) writes are deferred: under a copying design,
multiple source buffers are equivalent to one concatenated copy, so there is
no correctness reason to support them yet. The name `uv-write*!` is reserved
for that API when it is added.

## Consequences

- No `lock-object` traffic on the read or write hot path, keeping the GC
  invariants (design spec §10) simple: the only locked objects in the whole
  binding are the eight static trampolines
  ([ADR-0008](0008-static-trampolines-and-handle-registry.md)).
- One clear allocation and one clear free site per operation kind, which is
  exactly what the debug counters key off
  ([ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md)).
- An extra copy on every read and every write, accepted as v0.1's cost;
  nothing has yet demonstrated this matters for the workloads this binding
  targets.
- The span-shaped `(bv start end)` read API and the reserved `uv-write*!`
  name exist so that adding zero-copy later is additive to the public API,
  not a breaking redesign of it.
