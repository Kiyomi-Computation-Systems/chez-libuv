# ADR-0002: Bind libuv directly via FFI; keep the C shim to constants only

- **Status:** Accepted (2026-08-18) — evidence: spike/FINDINGS.md Q1/Q2. Amended 2026-09-27 (issue #35): a fifth kind of export, bulk byte moves — see the dated note inline. Amended 2026-10-05 (issue #45): a sixth kind, libuv's alloc callback for reads — see the dated note inline.
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0001](0001-hybrid-native-dependency-acquisition.md)

## Context

`chez-cmark-gfm`'s C shim wraps every native call it needs, because cmark-gfm
is a tree-ownership API where the interesting work — traversal, in that
project's case — was deliberately moved to the Scheme side, leaving the C
layer thin but still call-wrapping. libuv is a different shape of problem: it
is already a small, stable, intentionally-directly-callable C API (`uv_*`),
not an ownership-transfer-heavy tree.

Two architectures were considered for the callback-bearing calls this binding
needs (`uv_read_start`, `uv_write`, `uv_timer_start`, and the rest):

- **Option A — direct FFI.** `foreign-procedure` bindings straight to `uv_*`
  symbols. The C shim exports nothing that wraps a libuv call; it exists
  purely to expose values C can compute that Scheme cannot obtain any other
  way (struct sizes and offsets, the errno enumeration, debug counters).
- **Option B — C trampoline layer.** Hand-written C wrapping every `uv_*`
  call this binding needs, mirroring the shape of the cmark-gfm shim. This
  insulates the Scheme side from libuv API churn but roughly doubles the
  hand-maintained C surface and reintroduces a second boundary — the shim's
  own header — that must stay synchronized with libuv's.

Option A is materially riskier: it requires `foreign-callable` trampolines
that libuv itself invokes asynchronously, re-entering Chez from inside a
blocking `uv_run` call, with GC pressure on that path. This is exactly the
callback machinery `chez-cmark-gfm` never needed, since cmark is synchronous
end to end. Stage 0's spike exists specifically to retire this risk before
committing to it (Q1: timer callback re-entry from inside `uv_run` under GC
pressure, 10,000 iterations).

## Decision

Bind `uv_*` functions directly via `foreign-procedure`. The C shim
(`libuv-shim.c`/`.h`) exports exactly four things: the compiled version
getter, the name-keyed constant lookup function, the errno enumeration, and
debug counters — never a function that itself calls into libuv on the
binding's behalf.

> **Amended 2026-09-27 (issue #35; the rejection reasons corrected
> 2026-09-28 after review).** A fifth kind of export: three bulk byte moves
> behind `copy-in!`, `copy-out` and `zero-out!`. They are `chez_uv_copy_in`
> and `chez_uv_copy_out` (one `memcpy` each) and `chez_uv_zero` (one
> `memset`).
>
> Scheme's own primitives move one scalar at a time between a bytevector and
> foreign memory (`foreign-set!`, `foreign-ref`), so the copy-at-the-boundary
> helpers ([ADR-0009](0009-copy-at-the-boundary.md)) looped a byte at a time,
> at ~29 ns a byte. That held a 4 MiB `uv-write!`'s loop ~250 ms: 122 ms
> zeroing the block and 125 ms copying the payload in. A `memcpy` moves
> 4 MiB in ~0.1 ms.
>
> The line this ADR draws still holds: none of the three calls into libuv.
> Every argument check stays in Scheme, before the call, because the shim
> trusts what it is handed.
>
> Binding libc's `memcpy` and `memset` directly would also have worked, and
> was rejected. The first version of this note gave the wrong reason: that a
> `u8*` argument cannot carry `copy-in!`'s start offset. Chez 10.4.1's
> `ftype-scheme-object-pointer` argument type passes an object's address
> plus an offset, and the reason never applied to `copy-out`, which copies to
> offset 0, or to `zero-out!`, which takes no bytevector. The reasons that
> hold are these:
>
> - **The symbols belong to the binding.** libc's `memcpy` resolves through
>   `foreign-procedure` only because libuv, loaded first, links libc:
>   `(foreign-entry? "memcpy")` is `#f` in a bare Chez. The shim's entries are
>   this binding's own, and a shim missing one fails the import with
>   `&uv-shim-unavailable` (`native.sls`'s `shim-procedure`).
> - **One argument covers every move.** Each passes a bytevector as `u8*` to
>   a plain call, so a single argument makes all three safe: a plain call
>   keeps its thread active, and no collection can move the bytevector before
>   the call returns (`test-threading-stress.sps` pins it). There is no offset
>   arithmetic on a live Scheme object to reason about.
> - **Windows** ([ADR-0004](0004-windows-deferred-design-clean.md)) would
>   likely need the C runtime's DLL named to bind libc, where the shim is
>   already loaded by path. This is plausible but unverified, since Windows
>   is deferred.

> **Amended 2026-10-05 (issue #45, item 5).** A sixth kind of export, and
> the first that libuv calls rather than Scheme: `chez_uv_alloc_cb`, the
> alloc callback `uv-read-start-native` hands `uv_read_start` in place of a
> Scheme trampoline ([ADR-0008](0008-static-trampolines-and-handle-registry.md),
> amended the same day).
>
> libuv calls the alloc callback before every read, and the binding's answer
> never varied: the stream's own read buffer, allocated at its first read
> start and freed by its close dispatcher. Crossing into Scheme for it cost
> a collect-safe reactivation of the loop thread and the seam's dispatch on
> every read: 416 B a read through libuv (864 B against 448 B,
> `tests/test-callback-alloc.sps`).
>
> Now the answer is in place before the first read. A handle that has
> started reading has a `data` field pointing at a `uv_buf_t` descriptor at
> the head of its read buffer, with the payload after it, and the callback
> copies the descriptor into libuv's `uv_buf_t`. A handle whose `data` is
> NULL gets the empty buffer, which libuv reports as `UV_ENOBUFS`, as the
> Scheme dispatcher answered for a handle with no buffer.
>
> The line this ADR draws holds: the callback calls nothing, in libuv or in
> Scheme. It reads one field of the handle libuv passes it and copies one
> struct. What it relies on:
>
> - **`data` belongs to the read path.** libuv never reads or writes a
>   handle's `data` (in `vendor/libuv/src`, only `uv_handle_get_data` and
>   `uv_handle_set_data` touch it), and nothing else in the binding sets it.
>   A feature that wants `data` for anything else has to move the
>   descriptor first.
> - **The descriptor lives exactly as long as the buffer, because it is
>   part of the buffer's block.** It is written once, when the block is
>   allocated, and freed with it by the close dispatcher, after libuv's last
>   alloc callback for the handle. `tests/test-tcp.sps` holds that `data`
>   points at the head of the read buffer, and the Linux Valgrind gate sees
>   the callback's reads: a descriptor freed early reads as an invalid read
>   in `chez_uv_alloc_cb` (`.plans/shim-alloc-mutation-log.md`).
> - **It has libuv's `uv_alloc_cb` type**, checked when the shim compiles.
>   Scheme passes only its address, so no call site would notice a drift.
> - **A shim built from older sources is still refused by name.**
>   `native.sls` fetches the address through `shim-entry`, which checks the
>   entry as `shim-procedure` does, and `tests/test-shim-loading.sps` loads
>   a shim built without the callback.
>
> Rejected: a block of its own for the descriptor, which would be a second
> allocation with a second lifetime to keep in step with the buffer's; and
> a table in C keyed by handle, which would be a lookup on every read for
> what one field already holds.

On Linux this requires libuv's own shared object to be `load-shared-object`'d
by absolute path *before* the shim is loaded, because Linux's per-object
`dlopen` namespacing means the shim would not otherwise see libuv's symbols
resolved when its own `foreign-procedure` declarations are evaluated. This
load-order requirement is recorded here because it is a direct structural
consequence of choosing Option A; a C-trampoline shim (Option B) would not
have needed it, since Option B's C code links against libuv itself at build
time rather than relying on Scheme-side symbol resolution.

If Stage 0's Q1 spike shows callback re-entry under Option A is unsafe, the
recorded fallback is Option B, without changing the public Scheme API the
layers above this binding depend on.

## Consequences

- The shim stays small — four exported entry points regardless of how many
  `uv_*` functions the binding eventually calls — which keeps the
  never-transcribe-constants policy
  ([ADR-0005](0005-constants-are-never-transcribed.md)) cheap to maintain.
  (Amended 2026-09-27 for #35: five kinds of export now. The fifth is three
  one-line functions, and "four" always counted kinds, not symbols.
  Amended 2026-10-05 for #45: six. The sixth is the one function libuv
  calls, and it calls nothing back.)
- The Linux load-order requirement becomes a hard invariant, enforced in
  `native.sls` and covered by `test-shim-loading`; getting it wrong fails at
  import time, not at first call.
- Direct FFI means libuv API surface changes propagate straight into Scheme
  bindings with no C-side insulation layer to absorb them — an accepted cost,
  since libuv's 1.x ABI is stable by libuv's own guarantee.
- This decision is the one most directly contingent on the Stage 0 spike;
  its status cannot move to `Accepted` before Q1's evidence is recorded.
