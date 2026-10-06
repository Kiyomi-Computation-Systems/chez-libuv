# ADR-0009: Copy at the FFI boundary; defer zero-copy without foreclosing it

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit. Amended 2026-08-18 (Stage 4): the Writes paragraph's free-vs-callback ordering was corrected — see the dated note inline. Amended 2026-08-30 (v0.5): two read-buffer-ownership facts recorded, established while rejecting a shared per-loop buffer — see the dated note inline. Realized 2026-09-19 (issue #18): the reserved `uv-write*!` vectored-write name now exists — see the dated note inline. Amended 2026-09-27 (issue #35): the copies, and the zeroing of every write block, became bulk moves — see the dated note in Consequences. Amended 2026-10-06 (DNS arguments): what a call checks, it copies, and only the copy reaches C — see the last bullet of Consequences. Amended 2026-10-06 (address strings): the same rule for the address `uv-tcp-bind!`, `uv-tcp-connect!` and `uv-getnameinfo!` hand libuv — see the same bullet. Amended 2026-10-06 (segment lists): `uv-write*!` reads its segment list once, each pair checked as it is read — see the same bullet.
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

> **Realized 2026-09-19 (issue #18).** The reserved name now exists.
> `uv-write*!` (`src/libuv/stream.sls`) copies its N segments into one request
> block laid out `[ req | uv_buf_t[N] | payloads ]` and issues `uv_write` with
> `nbufs = N` — `uv-write-native` already threaded the count
> (`src/libuv/private/native.sls`), and `uv-write!` is the caller that pins it
> at 1. This ADR's own reasoning is why the addition is cheap: under a copying
> design a vectored write is still *one* owned block, so the completion and
> the free-**before**-`on-complete` discipline are `uv-write!`'s unchanged, and
> both this ADR's amended free order and ADR-0018's submit-immediately rule
> hold verbatim for the new verb. A segment is a whole bytevector or an
> explicit `(bv start end)` span; libuv refuses `nbufs < 1`
> (`vendor/libuv/src/unix/stream.c:1309`), so an empty segment list is refused
> at the boundary with a named reason rather than forwarded as a platform
> `EINVAL`. The driving consumer is the chez-http-server response path (status
> line + headers + body chunks in one write) the deferral paragraph above
> anticipated.

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

  > **Amended 2026-09-27 (issue #35).** Something has, but the cost came from
  > how the copies were written, not from copying. Both directions ran as
  > byte-at-a-time Scheme loops at ~29 ns a byte, and so did the zeroing
  > `alloc-zeroed` gives every write block before the payload overwrites it.
  >
  > chez-http-server's M5 exit saw a 4 MiB `uv-write!` hold its loop 254 ms.
  > Measured here, the call took 247–251 ms: 122 ms zeroing plus 125 ms
  > copying. At the measured 28.6 ns a byte, a 16 KiB read's copy works out
  > to ~0.47 ms (computed, not timed).
  >
  > Each helper is now one `memcpy` or `memset` through the shim
  > ([ADR-0002](0002-direct-ffi-with-constants-only-shim.md), amended the same
  > day). The same 4 MiB write now takes 0.41–0.54 ms.
  >
  > Copying at the boundary is unchanged, and the moves add no `lock-object`.
  > The bytevector crosses as a `u8*` argument to a plain call, not a
  > `__collect_safe` one. A plain call keeps its thread active, and the
  > stop-the-world collector waits for every active thread
  > ([ADR-0019](0019-threading-model-collect-safe-and-per-loop-affinity.md)
  > fact 1), so the storage cannot move before the call returns.
  >
  > **The price of that plain call** (recorded 2026-09-28, after review): on
  > a threaded Chez, every other thread's collection waits for the whole
  > move. The old per-byte loop never made other threads wait, because it
  > reached safe points, though its own thread took seconds.
  >
  > Measured while an allocating thread ran beside a write-shaped move, on
  > macOS arm64:
  >
  > | move | that thread's collections waited |
  > |---|---|
  > | 4 MiB | under 0.7 ms |
  > | 64 MiB | 3–9 ms |
  > | 256 MiB | 13 ms warm, 87 ms on fresh pages |
  >
  > The glibc image's slower `memcpy` stretches these times.
  >
  > Chunking the move would bound the wait only with small chunks. A loop of
  > plain foreign calls notices a pending collect request about once every
  > 490 calls, so 1 MiB chunks bound nothing. 64 KiB chunks bound the wait to
  > ~1 ms for ~10% more copy time, and each chunk would have to repeat
  > `copy-in!`'s span check.
  >
  > The moves stay unchunked: the wait matters only for single writes of tens
  > of MiB, which a consumer writing under backpressure already splits.
  > docs/api.md's `uv-write!` row states the cost. Making the call
  > `__collect_safe` is not an option: a concurrent collection then moves the
  > bytevector mid-copy and corrupts it.
  >
  > **The span check and the copy are one step** (added 2026-09-28, after
  > review). `copy-in!` checks its span against the bytevector's length
  > inside the same `with-interrupts-disabled` region as the `memcpy`. Were
  > an interrupt handler to run between the two, an engine's timer for
  > instance, and truncate the bytevector, the copy would read past its new
  > end, and a `uv-write!` would send the heap behind it to the peer. The old
  > loop re-checked every index.
  >
  > **A refusal from that step frees the write's block** (added
  > 2026-10-05). A write verb allocates its block after its own span check
  > and before the copy, so the step can refuse with the block allocated and
  > not yet registered. That refusal used to be `copy-in!`'s raise, and
  > nothing freed the block. Every write whose payload an engine's timer
  > handler, or another thread, truncated in that window leaked it; the shape
  > dates from v0.1.0. The step now answers the refusal as a status
  > (`try-copy-in!`), and each verb frees its block before raising its own
  > refusal: `uv-write!`'s `span-out-of-range`, or `uv-write*!`'s
  > `segment-span-out-of-range`. A `guard` around the copy would also free
  > it, at ~300 B a write (#45).
  >
  > What holds it:
  >
  > - `tests/test-stream.sps`'s shrinking-payload sweep holds the refusal and
  >   the bytes sent. It overwrites the payload before truncating it, so a
  >   copy that read past the new end would show.
  > - Valgrind holds the free.
  > - The late refusal looks the same as each verb's own up-front span check,
  >   so `tests/test-tcp.sps` holds that check with an end only it can refuse
  >   cleanly.
  >
  > `.plans/write-copy-leak-mutation-log.md` has the evidence.
  >
  > **The write verbs now check the span before they allocate** (added
  > 2026-10-06). Each write is one interrupt-free step: the stream's open
  > check, the span checked again, the allocation, the copy
  > (`copy-in-unchecked!`, since the step has checked the span itself),
  > the registration and `uv_write` (ADR-0019's decision 3, amended
  > 2026-10-06). A span the payload no longer covers is refused before any
  > block exists, so there is nothing left to free; the shrinking-payload
  > sweep holds the same refusals, and Valgrind finds nothing to hold.
  > `try-copy-in!` stays as `copy-in!`'s base.
  >
  > **What pins all this:**
  >
  > - `tests/test-native.sps` holds each helper within 3x of libc's own
  >   `memcpy` or `memset` over the same bytes, and runs the truncation scan.
  > - `tests/test-stream.sps` holds each write verb within 3x of libc
  >   allocating, zeroing and copying the same bytes.
  > - `tests/test-threading-stress.sps` pins the plain binding.
  >
  > `.plans/bulk-copy-mutation-log.md` has the evidence.
- The span-shaped `(bv start end)` read API and the reserved `uv-write*!`
  name exist so that adding zero-copy later is additive to the public API,
  not a breaking redesign of it.
- **What a call checks, it copies, and only the copy reaches C** (added
  2026-10-06). A check of caller-owned data and a later read of the same
  data are two readings, and an engine's timer handler, or another thread,
  can change the data between them. `uv-getaddrinfo!` read its arguments
  twice from v0.2.0 on. It validated its node, service and hints, then wrote
  the hints into the request block after allocating it, and Chez's `string`
  argument encoded node and service during the native call. A hint turned
  bogus in between was refused with the block allocated and unregistered,
  and nothing freed it. A NUL written into the node reached libuv as a
  shorter name: `"127.0.0.1"` resolved as `0.0.0.127`.

  The validators now answer copies, made by the walk that checks them, and
  the call allocates and writes from the copies alone: node and service as
  their NUL-terminated UTF-8, passed as `u8*`, and the hints as ints.

  Chez's own string primitives read twice as well (Chez 10.4.1, measured).
  `string->utf8` counts a string's bytes, allocates, then encodes. An engine
  can expire in between once the string is 64 characters or more, and a
  character widened then is encoded past the end of the result; another
  thread can do the same without an engine. `string-copy` reads the length,
  allocates, then copies, and a string truncated and collected in between is
  read past its end. So a string is copied with interrupts disabled, which
  runs no handler and no collection inside the copy, and the private copy is
  what gets encoded. A copy is fixed-width, so another thread cannot make it
  overrun.

  `tests/test-dns.sps`'s changed-argument sweeps hold the lookup,
  `tests/test-addrinfo.sps`'s sweeps and cross-thread race hold the copies,
  and `tests/test-native.sps` holds that only one C string crosses. Valgrind
  holds the free. `.plans/getaddrinfo-snapshot-mutation-log.md` has the
  evidence.

  The address verbs had the same two readings, from v0.1 and v0.2 on:
  `require-address` checked only that the address was a string, and Chez's
  `string` argument encoded it during `uv_ip4_addr`, then again during
  `uv_ip6_addr`. An embedded NUL was never refused, so
  `"127.0.0.1\x0;anything"` was bound, connected to and reverse-resolved as
  `127.0.0.1`, and a NUL written into `"::1"` during the call made it `"::"`:
  `uv-tcp-bind!` bound every interface instead of loopback, `uv-tcp-connect!`
  was handed the unspecified address, and `uv-getnameinfo!` resolved `"::"`. `validate-address` now answers the
  address's C string, from the copy above (`c-string-bytes`, which
  `(libuv private c-string)` holds for both), and `fill-sockaddr!` passes
  libuv those bytes as `u8*`, refusing anything that is not one C string.
  `tests/test-address.sps`'s sweeps hold the three verbs;
  `.plans/address-snapshot-mutation-log.md` has the evidence.

  `uv-write*!` read its segment list twice too, the second time without
  checking what it read (#64). It asked `list?`, then parsed the list with
  Chez's `map`, which counts a list and then walks it without checking its
  pairs again. A non-pair put into the list during the walk, by an engine's
  timer handler or another thread, was read through: `invalid memory
  reference` at fuels 19 to 23 of `tests/test-stream.sps`'s cut sweep (Chez
  10.4.1, macOS arm64). A list made circular there was walked without end,
  in a walk no engine's fuel stops, until the process held about 6 GB.
  `proper-length`, which `fold-flags` counts with, had a smaller form of the
  fault: its tortoise took the cdr of whatever it found behind the hare, and
  raised for a list of twelve cut during the count. Now `proper-length` takes
  every cdr of a value just found to be a pair. `uv-write*!` counts its list
  with it, walks at most that many pairs, checking each and requiring the
  list's end after them, and reads each `(bv start end)` span once the same
  way. `tests/test-stream.sps`'s segment-list sweeps hold the verb,
  `tests/test-native.sps`'s sweeps hold the count, and
  `.plans/write-segments-mutation-log.md` has the evidence.
