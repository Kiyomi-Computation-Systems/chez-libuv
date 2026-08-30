# ADR-0009: Copy at the FFI boundary; defer zero-copy without foreclosing it

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit. Amended 2026-08-18 (Stage 4): the Writes paragraph's free-vs-callback ordering was corrected — see the dated note inline. Amended 2026-08-30 (v0.5): two read-buffer-ownership facts recorded, established while rejecting a shared per-loop buffer — see the dated note inline.
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0002](0002-direct-ffi-with-constants-only-shim.md),
  [design spec v0.5](../2026-08-29-chez-libuv-v0.5-flow-control-design.md) §7.2, §7.4, Appendix A condition 9

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

> **Amended 2026-08-30 (v0.5).** Two facts about read-buffer ownership,
> established while rejecting a shared per-loop buffer as a memory
> optimization at high connection counts (design spec v0.5 §7.3, Appendix A).
>
> **First:** `uv__read` is a loop, not a single call:
>
> ```c
> while (stream->read_cb
>     && (stream->flags & UV_HANDLE_READING)
>     && (count-- > 0)) {
>   assert(stream->alloc_cb != NULL);
>   buf = uv_buf_init(NULL, 0);
>   stream->alloc_cb((uv_handle_t*)stream, 64 * 1024, &buf);
>   ...
> }
> ```
> (`vendor/libuv/src/unix/stream.c:1043-1049`) — `alloc_cb`, `read()`,
> `read_cb`, then again unless the read did not fill the buffer. A handle's
> buffer is therefore already overwritten immediately after `on-data`
> returns, on a busy socket, before this binding's own machinery does
> anything at all. Callback-scoped borrowing is the natural lifetime under
> *any* ownership model — per-handle or per-loop makes no difference here —
> and the `(bv start end)` span shape this ADR reserves above remains right:
> nothing about a future zero-copy variant needs to change shape to hand
> back a borrowed sub-range for the duration of one callback.
>
> **Second, correcting an assumption made when this ADR was written:**
> read-stop does **not** make a retained span safe. `uv-read-stop!` stops
> the read loop from overwriting the buffer, but the close dispatcher frees
> it unconditionally, on every close, regardless of read state:
>
> ```scheme
> (define (close-dispatch handle-ptr)
>   (let ((handle (registry-ref handle-ptr)))
>     (if (uv-handle? handle)
>         (begin
>           (registry-deregister! handle-ptr)
>           (free-read-buffer! handle)
>           (free! handle-ptr)
>           ...
> ```
> (`src/libuv/private/handles.sls:984-990`) — so a span retained across
> callbacks becomes a use-after-free the instant the handle closes, and
> close can be initiated from anywhere, including a teardown sweep the
> holder of the span may know nothing about. A retained-borrow design needs
> explicit borrow ownership of its own — a token, a refcount, a deferred
> close, or an equivalent rule coordinating close against outstanding
> borrows — none of which exists today. "Read-stop already makes this safe"
> was wrong; recorded as Appendix A condition 9 of the v0.5 design spec.

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
