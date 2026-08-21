# ADR-0011: DNS requests are handle-less, loop-scoped registry entries; teardown cancels then drains them

- **Status:** Proposed (2026-08-21) — pending Stage 0 DNS spike evidence (spike/dns/FINDINGS.md)
- **Date:** 2026-08-21
- **Scope:** chez-libuv v0.2
- **Related:** [design spec](../2026-08-21-chez-libuv-v0.2-dns-design.md),
  [ADR-0007](0007-no-guardians-explicit-close.md),
  [ADR-0008](0008-static-trampolines-and-handle-registry.md),
  [ADR-0009](0009-copy-at-the-boundary.md)

## Context

Every v0.1 request runs on a handle: a write or shutdown on a stream, a
connect on a TCP handle. `uv-req-record`'s `handle` field is documented as
"the only route from a completion back to the owning loop"
(handles.sls:308-312), and `complete-request!` takes exactly that route —
`(handle-loop (req-handle req))` at handles.sls:599, which is the sole
reader of `req-handle` in the tree (grep-verified). The teardown sweep
likewise excludes request entries from its close sweep on a rationale that
leans on handle ownership (handles.sls:433-439): libuv fires every request
callback before the close callback of the handle it belongs to, so closing
the handle is what flushes — and thereby frees — the in-flight request.
Both the field's doc comment and that rationale are true only of
handle-owned requests.

`uv_getaddrinfo_t` and `uv_getnameinfo_t` break the pattern: they are
requests with **no owning handle at all**. Their start calls take the loop
directly (vendor/libuv/include/uv.h:1002-1027), the work runs on a
threadpool worker as pure libc `getaddrinfo(3)`/`getnameinfo(3)`
(vendor/libuv/src/unix/getaddrinfo.c:96-103), and the done callback fires
on the loop thread (vendor/libuv/src/threadpool.c:319-342). With no handle
there is nothing for `complete-request!` to read the loop from, and no
close whose callback ordering would flush an in-flight request at teardown.

Three vendor facts bound the possible designs (pinned v1.52.1):

- An active request keeps the loop alive — `uv__loop_alive` counts active
  reqs (vendor/libuv/src/unix/core.c:393-397) — so a drain's
  `uv_run 'default` **blocks**, rather than returning early or spinning,
  until the worker posts `wq_async` (threadpool.c:126-131, 319-342).
- `uv_loop_close` answers `EBUSY` while a request is pending
  (vendor/libuv/src/uv-common.c:885), exactly as it does for open handles.
- `uv_cancel` returns `0` only while the work item is still queued; the
  callback then **still fires**, with `UV_ECANCELED` rewritten to
  `UV_EAI_CANCELED` for both DNS request types (threadpool.c:399-441;
  getaddrinfo.c:128-133; getnameinfo.c:64-67). Running or completed work
  answers `UV_EBUSY` and delivers its real result. Exactly one callback in
  every outcome, double-cancel included.

## Decision

**Reuse `uv-req-record` with `handle = #f`.** No new record type. The
record (handles.sls:313-321) already takes its fields positionally; DNS
start calls pass `#f` for the handle, record kinds
`'getaddrinfo`/`'getnameinfo`, and the completion path stays the one that
already exists — preserving the property that a request block is freed in
exactly one place (handles.sls:565-567). The `handle` field's doc comment
is amended to scope its "only route to the loop" claim to the handle-owned
kinds, with `#f` a documented legitimate value.

**`complete-request!` resolves the loop from the registry entry, not the
record.** The read at handles.sls:599 becomes `registry-loop-of`
(handles.sls:424-426), performed **before** the deregister — the entry
provably exists at that point, because the `registry-ref` on the previous
line just succeeded on the same key, and the entry's loop was validated
`uv-loop?` at the one place it is ever written (registry-register!,
handles.sls:393-395). For the three TCP kinds this is behavior-preserving
by construction: every TCP request registers its handle's loop
(tcp.sls:244, 304, 323), so entry-loop and `(handle-loop (req-handle req))`
are the same object, and the TCP suite guards the equivalence. One code
path serves all five request kinds.

**Delivery is generalized to `(apply on-complete err extras)`**, where
`extras` are always already-copied Scheme values computed before
`complete-request!` frees anything (ADR-0009's boundary: getaddrinfo's
converted record list, getnameinfo's two copied strings — both point into
memory that is gone by delivery time otherwise). Existing dispatchers pass
no extras, so v0.1 call sites are untouched.

**DNS requests register with the loop explicitly**, under registry kinds
`'getaddrinfo-req`/`'getnameinfo-req` — `registry-register!` already takes
the loop as an argument (handles.sls:380); TCP merely happened to pass the
handle's. `handle-kinds` (handles.sls:372) is untouched, so
`registry-snapshot-for-loop` (handles.sls:440-450) keeps request entries
out of the teardown close sweep automatically, and registry membership
remains what keeps the record and its `on-complete` closure reachable
across threadpool flight (ADR-0007/0008 — no guardian, no per-request
lock).

**`uv-loop-teardown!` gains a cancel sweep before the close sweep:
cancel-then-drain.** A new handles.sls export, `cancel-requests-for-loop!`,
takes a snapshot first — the same R6RS iterating-while-mutating rationale
as the close sweep's snapshot (loop.sls:210-214); `uv_cancel` mutates no
registry state, but the snapshot costs nothing and removes the question —
then walks this loop's DNS request entries and calls `uv_cancel` on each
live pointer, best-effort, **return codes ignored**: `0` means the queued
item completes on the next drain iteration with `'EAI_CANCELED`; `EBUSY`
means the work is running or finished and the drain waits it out. The
existing drain (loop.sls:254-264) then delivers every in-flight
`on-complete` before teardown returns — `'EAI_CANCELED` where cancel won,
the real result otherwise — inside `drain-step`'s existing
`&uv-callback-error` containment. The sweep lives in handles.sls (which
adds `uv_cancel` to its narrow native import); the public `uv-cancel!`
policy stays in `(libuv dns)`; both are thin callers of the one raw
binding, and loop.sls never imports `(libuv dns)`.

**`uv-loop-close!` is unchanged for DNS.** A pending request makes
`uv_loop_close` answer `EBUSY` (vendor/libuv/src/uv-common.c:885), which
already surfaces through `uv-check` as `&uv-errno-error` with errno
`'EBUSY` and the loop untouched and usable — the identical contract open
handles get (loop.sls:159-164). libuv's own guard is the check; adding a
Scheme-side one would be a comment wearing a check's clothes.

## Consequences

- **Exactly one callback in every outcome is preserved** across cancel-won,
  cancel-lost, double-cancel, and teardown — it is libuv's own threadpool
  property (threadpool.c:399-441) and the binding adds no path that could
  duplicate or drop a delivery. The claim carries one documented caveat:
  the getaddrinfo dispatcher's conversion-failure arm frees the block
  through the same deregister/free/count/zero sequence **without**
  delivering `on-complete`, surfacing via `loop-record-error!` instead —
  the callback is never invoked with fabricated data. That arm is
  reachable only through a dispatcher bug, not through user code or
  resolver behavior.
- **The cancel sweep runs once.** An `on-complete` that receives
  `'EAI_CANCELED` during the drain and submits a *new* DNS request gets
  that request drained — waited out to its real completion — not
  cancelled. Same once-only shape as the v0.1 close sweep; callers who
  submit work from teardown-delivered callbacks extend the drain, they do
  not escape it.
- **Teardown's duration acquires a wall-clock residual.** A `getaddrinfo(3)`
  already running on a worker is uninterruptible (`uv_cancel` → `EBUSY`),
  so the drain's one blocking iteration for it is bounded only by the OS
  resolver's own timeout. The 1024-iteration cap (loop.sls:206) is
  unaffected — an in-flight request costs at most one *blocking* iteration,
  not many — but "failure is iteration exhaustion, never wall-clock" now
  holds with this documented exception, stated in the module header and
  README. The alternative — abandoning the block while a worker may still
  write into it — is a use-after-free by design, and is rejected.
- **Rejected alternative: a new `uv-dns-request` record type** (fields
  ptr/kind/loop/on-complete). It buys only type-honesty — no `handle` field
  holding `#f` — and the objection it answers is a strawman, since the
  field stores `#f`, not a loop masquerading as a handle. Its cost is
  concrete: `complete-request!` as written rejects a non-`uv-req?` at
  handles.sls:598 and would file every DNS completion as an orphan, so the
  new type needs either a parallel completion-and-freeing path or a
  duplicated `complete-request!` — a second freeing site, forfeiting the
  one property (handles.sls:565-567) that makes request memory auditable,
  for no capability the `#f` handle does not already deliver.
- Two v0.1 comments become amendments rather than truths: the `handle`
  field's "only route from a completion back to the owning loop"
  (handles.sls:308-312) and the teardown sweep's request-exclusion
  rationale (handles.sls:433-439), both now explicitly scoped to
  handle-owned requests, with handle-less requests covered by the cancel
  sweep this ADR adds.
- The `registry-loop-of` substitution makes the registry entry, not the
  record, the authority on ownership — one more responsibility on the
  structure ADR-0008 already made dual-purpose, guarded by the existing
  validation at its single write site and by the TCP suite's unchanged
  behavior. A mutation that breaks the resolution fails the DNS suite by
  name; the TCP suite pins the equivalence for the handle-owned kinds.
