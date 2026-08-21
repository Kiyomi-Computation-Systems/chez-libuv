# ADR-0014: Stream state is a `uv-stream-record` intermediate; the stream verbs move to `(libuv stream)`

- **Status:** Accepted (2026-08-21) — evidence: spike/process/FINDINGS.md SQ3
- **Date:** 2026-08-21
- **Scope:** chez-libuv v0.3
- **Related:** [design spec](../2026-08-21-chez-libuv-v0.3-process-design.md) §3, §4.6, §5.1,
  [ADR-0007](0007-no-guardians-explicit-close.md),
  [ADR-0008](0008-static-trampolines-and-handle-registry.md),
  [ADR-0009](0009-copy-at-the-boundary.md)

## Context

v0.1 had exactly one stream, so the whole read path lives on the TCP record:
`on-data`, `on-eof`, `on-error`, `read-buf`, `read-buf-len`, `reading` are
fields of `uv-tcp-record` (handles.sls:297-309), and every consumer of them
tests `uv-tcp-record?` — `alloc-dispatch` (handles.sls:771-777),
`read-dispatch` (handles.sls:803-810), `free-read-buffer!`
(handles.sls:894-901) — while the four public verbs sit in `(libuv tcp)`
behind `require-open-tcp` (tcp.sls:50, exported at tcp.sls:35-36).

None of the natives underneath were ever TCP-specific. `uv_read_start`,
`uv_read_stop`, `uv_write` and `uv_shutdown` take `uv_stream_t*`; the
binding declares all four as `uptr` (native.sls) and the *only* thing that
makes them TCP-shaped is the Scheme-side kind test. The record comment
already anticipated the shape question and answered it for v0.1's scope:
"a record's field list is its layout. Adding fields later is a recompile of
every importer" (handles.sls:282-285).

v0.3 introduces a second stream. `uv_pipe_t` is not a variation on the read
path — it *is* the read path: SQ3 drove **200,100 round trips** through
`uv_pipe_t` parent ends with `(collect)` in every callback and recorded
`alloc callbacks / read callbacks : 200220 / 200220`, `payload verification
failures : 0`, `read errors (other than UV_EOF) : 0`, on both platforms.
Pipes go through `alloc_cb`/`read_cb`/`write_cb`/`shutdown_cb` with exactly
the semantics tcp does, measured rather than assumed.

Against today's code that measurement is also the bug report. A pipe handle
reaching `read-dispatch` fails `uv-tcp-record?` and is filed by
`record-orphan-callback!` (handles.sls:810): every byte the child wrote
would be *dropped as an orphan*, silently, with no delivery and no error.
The gap is at the record layer, not in libuv and not in `native.sls`.

## Decision

**One new intermediate record type, `uv-stream-record`, between
`uv-handle-record` and the stream children**, holding the complete
stream-generic field set hoisted out of the TCP record — `read-buf`,
`read-buf-len`, `reading`, `on-data`, `on-eof`, `on-error`. `on-connection`
stays on `uv-tcp-record`, because `uv-listen!`/`uv-accept!` remain TCP-only
(design spec §1 non-goals). The hierarchy becomes handle → stream →
{tcp, pipe}, with `uv-timer-record` and the new `uv-process-record` direct
children of handle (design spec §5.1): **a process is a handle, not a
stream** — it has no read path to inherit and inheriting one would give it
six fields no code may ever set.

**The accessors rename with the fields** (`tcp-read-buf` → `stream-read-buf`,
`tcp-on-data` → `stream-on-data`, …). This is a mechanical rename of every
reader in handles.sls; the *semantics* travel unchanged, including the one
field whose meaning is deliberate and documented: `reading` records **caller
intent**, not libuv's live read state (handles.sls:289-296), and the EOF and
error dispatchers still leave it set.

**The three gating arms widen from `uv-tcp-record?` to `uv-stream-record?`**
— `alloc-dispatch`, `read-dispatch`, `free-read-buffer!` — which is the
whole of the fix. `free-read-buffer!` in particular stays a *single* freeing
site for read buffers (handles.sls:894-901), which is the property the arm
exists to hold.

**The four stream verbs move to a new `(libuv stream)`**, gated by
`require-open-stream` — kind check first, state check second, the order the
existing gates use. `(libuv tcp)` re-exports all four so no importer changes,
and the facade re-exports them from `(libuv stream)` (design spec §3, §4.6).
Signatures, callback contracts, copy discipline (ADR-0009) and the
free-before-`on-complete` ordering are untouched: this ADR widens a
predicate and moves a definition, and deliberately changes nothing else.

**`uv-pipe-record` adds exactly one field of its own, `connected?`**, which
starts `#f` and flips when a spawn consumes the pipe — the observable that
makes `'pipe-already-used` raisable before any allocation (design spec §5.1,
and see [ADR-0015](0015-spawn-copy-lifetime-and-failure-path.md) for what a
*failed* spawn does to it).

## Consequences

- **Read-buffer memory keeps exactly one freeing site** for both stream
  kinds. That is the whole reason the intermediate type exists rather than a
  copied field set, and it is checkable: the close dispatcher's buffer arm is
  one `when`, and the counters (`count-read-buffer-free!`) balance per suite.
- **Rejected: duplicate the six fields onto `uv-pipe-record`.** It needs no
  new type and no rename — and it forfeits the property above: two records
  carrying a `read-buf` means two places that free one, which is the shape
  ADR-0011 rejected for request blocks for the same reason. The dispatchers
  would also grow a two-armed kind test each, in the three hottest callback
  bodies in the tree.
- **Rejected: keep the verbs in `(libuv tcp)` and let them accept pipes.**
  `require-open-tcp` would have to stop meaning what its name says, and
  `(libuv pipe)` would depend on `(libuv tcp)` for the ability to write to a
  pipe — a module cycle in the layering, and a name that lies about its own
  check.
- **Every existing TCP importer compiles unchanged**, because tcp.sls
  re-exports the moved names; test-tcp.sps and test-echo.sps are the
  regression that proves it, run untouched (design spec §9.3).
- The gating matrix becomes testable in its own right: `test-stream.sps`
  drives each verb against tcp, pipe, timer and closed handles, and the
  refuses-a-process row joins once `uv-spawn!` exists to construct one
  (design spec §9.3, §11 Stage 5).
- `handle-kinds` widens `'(timer tcp)` → `'(timer tcp pipe process)`
  (handles.sls:396), so `uv-loop-teardown!`'s close sweep covers both new
  kinds automatically and the two new counter pairs join `live-counts`.
  Nothing in the sweep learns a new special case.
- **The constructor protocols change shape.** `uv-tcp-record`'s
  `(pargs->new ptr 'tcp loop)` now threads through the stream parent's six
  fields before its own; a mis-ordered protocol is a construction-time
  failure in every TCP test, not a silent field mix-up — the record system
  positions fields by declaration order and the suites read them by name.
- ADR-0008's registry is unaffected: dispatch still resolves `uptr` → entry →
  record, and only the type test inside the seam closure widens. No new
  trampoline is implied by this ADR (the eleventh is the `exit` callback —
  see ADR-0008's v0.3 amendment).
