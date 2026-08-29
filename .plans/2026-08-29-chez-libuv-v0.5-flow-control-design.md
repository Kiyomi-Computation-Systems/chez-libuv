# Design Spec: chez-libuv v0.5 — Flow Control Mechanism

Status: **Draft** (five-lens adversarial review folded in 2026-08-29;
maintainer review folded in 2026-08-29; awaiting approval)
Date: 2026-08-29
Branch: `feat/v0.5-flow-control`

v0.5 adds no new libuv subsystem and **changes no behaviour**. It closes a gap
the first four milestones left open: at high connection counts, chez-libuv's
per-connection memory costs are neither visible nor adjustable, and its write
side offers no congestion signal at all. Both are mechanism problems, fixable
without the binding acquiring a line of connection-state or backpressure
*policy*.

Driving use case: a WebSocket or HTTP server holding 1,000–10,000 concurrent
connections on one loop. Three per-connection memory surfaces, only one of
which the spec's first draft noticed:

- **The chez-libuv read buffer.** 65536 bytes per handle
  (`src/libuv/stream.sls:136`), allocated on the first `uv-read-start!` and held
  until close: **625 MiB at 10k streams**, before a byte moves. The size lever
  already exists and is undocumented.
- **The OS receive buffer.** Linux autotunes `SO_RCVBUF` from roughly 87 KB
  upward per socket. At 10k connections this plausibly **exceeds** the read
  buffers, and today the binding cannot read it, let alone set it.
- **Outstanding write blocks.** One `foreign-alloc` per request
  (`stream.sls:85-92`), bounded by the consumer — see §4.1 for what that bound
  can and cannot be.

These are three independent quantities. Setting `SO_RCVBUF` does not resize the
chez-libuv read buffer, and vice versa; the documentation must say so, because
the names invite the confusion.

## 1. Goal and non-goals

**Goal.** Make all three per-connection memory surfaces visible and adjustable
from Scheme, and give the consumer the one congestion quantity it cannot
derive. Every addition reports or configures. **Nothing refuses, queues, or
decides** — including the read-buffer default, which this milestone deliberately
does not change (see below).

**Non-goals.**

- **No default-size change.** The first draft proposed 65536 → 16384 and
  justified it on memory alone. That was wrong on its own terms: a smaller
  buffer means proportionally more `on-data` deliveries, and every delivery
  allocates a fresh bytevector (`handles.sls:939`), so 16384 quadruples Scheme
  allocation churn for the same bytes. The tradeoff is memory against GC
  pressure against syscalls, and no measurement exists. §10 measures it; a
  follow-up sets the default with evidence and its own ADR. v0.5 ships the
  **lever, the documentation, and the pin** that make that follow-up safe.
- **No bounded write queue in the binding.** Rejected with reasons recorded in
  §11 and ADR-0018.
- **No shared per-loop read buffer.** §7.3 records why the rejection survives
  adversarial attack, on two structural grounds no measurement can move.
  Appendix A carries the conditions any future attempt must satisfy.
- **No zero-copy reads.** ADR-0009 stands. §7.4 records what each ownership
  model costs zero-copy — including a close-time hazard the first draft missed.
- **No release-build allocation counters.** Deferred; §12.1.
- **No `orphan-events` cap.** Deferred; §12.2.
- **No admission control, and no binding-owned connection table.** §9 records
  the ownership protocol the layer above needs, because one binding hazard makes
  it non-obvious. The policy stays upstairs.
- **No WebSocket anything.** Separate project, separate spec.
- **No new library module.**

## 2. Decisions summary

| # | Decision | Rationale |
|---|---|---|
| D1 | Document the read-buffer sizing lever; **pin the current default at 65536** | The lever exists and is undiscoverable; no test pins the default (§13.1). Pinning it now is what lets the follow-up change it safely. |
| D2 | Bind `uv_stream_get_write_queue_size` as a **platform-dependent congestion signal** | The one quantity Scheme cannot derive. Narrowed semantics — §4.1. |
| D3 | Bind `uv_send_buffer_size` / `uv_recv_buffer_size` in `(libuv handle)` | The OS socket buffers are a first-class per-connection memory lever, plausibly the largest one. Independently: a prerequisite for testing D2 deterministically. |
| D4 | Bind `uv_tcp_getpeername` | Completeness of the mirror; no Scheme substitute. Enables per-IP policy upstairs. |
| D5 | Correct **both** overlapped-model comments; add a `check-pins` vendor tripwire | The stated mechanism is dead code for the bound handle kinds (§7.1). Under AGENTS.md's "prefer a check to a comment", the replacement is a check. |
| D6 | Version → 0.5.0 in `Akku.manifest` **and** `CHANGELOG.md` together | `check-pins` fails otherwise (`Makefile:226-237`). All **Added**; no **Changed** entry, since nothing changes. |

## 3. Blast radius

```
src/libuv/stream.sls          D2 (uv-stream-write-queue-size), D5 (:187)
src/libuv/handle.sls          D3 (four procedures)
src/libuv/tcp.sls             D4; re-exports D2
src/libuv/private/native.sls  four *-native bindings + exports
src/libuv/private/handles.sls D5 (the second comment, :1001)
src/libuv.sls                 facade: six new names
Makefile                      D5 tripwire + its `## ` help text (:195)
README.org                    ADR count 17 → 18; version status line
CHANGELOG.md, Akku.manifest   D6
docs/api.md                   six export rows; new reason symbols (:286-294);
                              Flow control section; the three-buffers table;
                              the uv-close! callback-drop hazard (§9)
.plans/decisions/0018-*.md    ADR-0018 (§11)
.plans/decisions/0009-*.md    dated amendment (§7.4)
tests/test-tcp.sps            the default pin (§13.1), peer-address rows
tests/test-facade.sps         six exercised exports; needs a connected pair
tests/test-native.sps         size_t and int-out-param round-trips at stub level
tests/test-flow.sps           NEW: congestion fixture, buffer-size wrappers,
                              cross-stream isolation
spike/flow/                   §10, FINDINGS.md, .gitignore
```

`(libuv handle)` currently imports only `(libuv private handles)`
(`handle.sls:26-27`); D3 adds a `(libuv private native)` import, which is why
§5.1's raw bindings carry the `-native` suffix.

Any new suite is auto-discovered by the `TESTS` wildcard and auto-enrolled in
the Valgrind lane via `MEMORY_TESTS := $(TESTS)`. Never add it to `PURE_TESTS`.

## 4. Public API

### 4.1 `uv-stream-write-queue-size`

```scheme
(uv-stream-write-queue-size stream) → exact non-negative integer
```

**Contract, stated portably.** libuv's platform-dependent count of queued
stream bytes:

- **Unix** counts bytes not yet handed to the kernel (`unix/stream.c:693-694`),
  and deliberately leaves the count non-zero after a failed write so the user
  stops writing (`unix/stream.c:719-724`).
- **Windows** counts the opposite thing: `write_queue_size` is incremented only
  in the `UV_SUCCEEDED_WITH_IOCP` branch, i.e. bytes the kernel has *accepted*
  into an overlapped send that has not completed (`win/tcp.c:986`). The
  immediate-completion branch sets `queued_bytes = 0` and never increments. The
  Unix failed-write behaviour is not universal either.

**Therefore: a congestion signal, not a memory gauge and not a portable measure
of kernel occupancy.** Thresholds require platform and workload calibration.
Callback status remains authoritative for whether a stream is healthy. Hard
memory safety rests on the payload-byte and request-count bounds below, with
this gauge supplemental.

**What the consumer can bound exactly — and what it cannot.** The first draft
claimed the consumer can measure held foreign memory exactly. It cannot. Each
`uv-write!` allocates `align-16(uv_req_size) + sizeof(uv_buf_t) + max(len, 1)`
(`stream.sls:85-92`), so a **zero-length write allocates a full request block
while contributing zero payload bytes** — outstanding payload bytes can stay at
zero while fixed-size blocks grow without bound. What the consumer can track
exactly is two quantities:

- **outstanding payload bytes**, and
- **outstanding request count**.

Together they are a deterministic bound; neither alone is, and their sum is not
an exact byte measurement of foreign memory. Increment **only after `uv-write!`
returns successfully** — a synchronous failure raises and produces no
completion callback (`stream.sls:99-104`, the `abandon-request!` guard).

**The gate.** `require-open-stream` (`stream.sls:39-43`). The native read cannot
fail — it is a struct field read (`uv-data-getter-setters.c:77`) — but the gate
can, and its removal is a genuinely silent mutation **on a closing handle**,
where the pointer is still live and the native returns a plausible number. On a
fully *closed* handle, `handle-pointer` (`handles.sls:471-475`) refuses the
zeroed pointer with `'null-handle-pointer` first, so the mutation surfaces as
the wrong condition rather than as nothing. §13.2's mutation therefore uses a
**closing** stream; a closed one does not discriminate.

`size_t`, not a signed type, and deliberately: this repo's scar is binding
`nread` unsigned, which routed `UV_EOF` into the data path as four gigabytes of
data (`handles.sls:889-895`). This is the opposite case — the value cannot be
negative and the call cannot fail.

### 4.2 `uv-send-buffer-size`, `uv-recv-buffer-size` and setters

```scheme
(uv-send-buffer-size handle)     → exact positive integer
(uv-send-buffer-size! handle n)  → unspecified
(uv-recv-buffer-size handle)     → exact positive integer
(uv-recv-buffer-size! handle n)  → unspecified
```

**Handle-generic, defined in `(libuv handle)` and exported from the facade.**
Not added to `(libuv tcp)` alone: ADR-0014 justified TCP *re-exports* to
preserve existing imports, which does not justify introducing new generic names
in `(libuv tcp)` while `(libuv pipe)` lacks them. `(libuv tcp)` re-exports D2
only, because that one is stream-shaped.

**Platform support is not uniform and the docs must say so.** Per
`vendor/libuv/docs/src/handle.rst:202`: TCP, pipe and UDP on Unix; **TCP and UDP
only on Windows**. The kind gate is an allowlist that fails closed, and it is
platform-conditional. A TCP handle needs a socket but **not a connection** —
`bind` is sufficient, and libuv's own tests configure a bound handle — so the
contract is "has an fd", not "is connected".

**Three distinct quantities, named together in `docs/api.md`** because the
names invite conflation:

| Quantity | Set by | Freed by | Typical scale |
|---|---|---|---|
| chez-libuv read buffer | first `uv-read-start!`, irreversibly | close dispatcher | 64 KiB default |
| OS send buffer | `uv-send-buffer-size!` | kernel, at socket close | tens of KB, tunable |
| OS receive buffer | `uv-recv-buffer-size!` | kernel, at socket close | autotuned, 87 KB+ on Linux |

Changing `SO_RCVBUF` does not resize the chez-libuv buffer.

**The get/set split.** libuv overloads one entry point on whether `*value` is
zero (get) or non-zero (set). That is a C calling convention, not an API worth
mirroring: a getter that silently becomes a setter when handed the wrong integer
is exactly the trap a legible mirror should be legible about. §13.3 carries the
row that proves the split holds — and it is not the naive one; see there.

The setter validates `n` **exact, positive, below 2^31** before the call,
raising `&uv-invalid-argument` with reason `'buffer-size-out-of-range`.
`c-int-set!` bottoms out in `foreign-set! 'int` (`native.sls:727-732`), which
raises a raw Chez exception outside the condition hierarchy for an
out-of-range value, so the check is what keeps the failure inside the documented
vocabulary.

Platform note: the kernel may round or double the request — Linux doubles and
returns double (`handle.rst:206`) — so a get after a set is not required to
return `n`.

### 4.3 `uv-tcp-peer-address`

```scheme
(uv-tcp-peer-address tcp) → (values address-string-or-#f port)
```

`uv_tcp_getpeername`, reusing `sockaddr->address-string` (defined
`native.sls:552`, exported `:94`) and the in-out-length discipline at
`tcp.sls:148-165`. The `(values address port)` shape is governed by ADR-0012.

**Failure contract.** `sockaddr->address-string` answers `string | #f`
deliberately, so the first value may be `#f`. An unconnected handle answers
`UV_ENOTCONN` through `uv-check`. A namelen too short for a port raises
`&uv-invalid-argument` with reason `'sockaddr-too-small-for-a-port`, matching
the sibling. **Tests must require the expected IPv4 string, never merely tolerate
`#f`** — an assertion that accepts `#f` passes against an implementation whose
address conversion is replaced by constant `#f` (§13.5).

**Deliberate asymmetry:** the local side exposes only
`uv-tcp-getsockname-port`, because what a caller needs locally is the ephemeral
port a zero-bind chose. `uv-tcp-sockname-address` on symmetry grounds alone is
deferred until something needs it.

### 4.4 Facade

**Six** names: `uv-stream-write-queue-size`, `uv-send-buffer-size`,
`uv-send-buffer-size!`, `uv-recv-buffer-size`, `uv-recv-buffer-size!`,
`uv-tcp-peer-address`.

`tests/test-facade.sps` is the suite whose *purpose* is the re-export list. Each
of the six must be **exercised**, not asserted about: enforcement is an
expand-time unbound identifier (`test-facade.sps:19-23`), so a
`(test-assert "… is re-exported" (procedure? …))` row enforces nothing and is
the truthiness trap besides. The setters need a connected pair — a fixture that
suite lacks, whose TCP work is a bind-and-read-port at `:294`. Budget it.

## 5. Internals

### 5.1 native.sls — four bindings, `-native` suffixed

```scheme
(define uv-stream-get-write-queue-size-native
  (foreign-procedure "uv_stream_get_write_queue_size" (uptr) size_t))
(define uv-send-buffer-size-native
  (foreign-procedure "uv_send_buffer_size" (uptr uptr) int))
(define uv-recv-buffer-size-native
  (foreign-procedure "uv_recv_buffer_size" (uptr uptr) int))
(define uv-tcp-getpeername-native
  (foreign-procedure "uv_tcp_getpeername" (uptr uptr uptr) int))
```

The suffix is not decoration: `(libuv handle)` must import
`(libuv private native)` to reach these, and the public wrappers share their
names. The repo already uses this convention (`uv-read-start-native`,
`uv-write-native`, `uv-shutdown-native`, `uv-listen-native`).

`size_t` is proven here (`native.sls:371-373`). All four are defined after
`load-shared-object` — a `foreign-procedure` resolves its entry point at
evaluation, so a misplaced definition fails at *import* time, pointing nowhere
near the mistake (AGENTS.md).

No shim function: ADR-0002 says the shim never wraps a `uv_*` call.

**The `int*` out-parameter is load-bearing.** libuv's discriminator reads the
caller's memory:

```c
len = sizeof(*value);
if (*value == 0)  r = getsockopt(fd, SOL_SOCKET, optname, value, &len);
else              r = setsockopt(fd, SOL_SOCKET, optname, (const void*) value, len);
```
(`vendor/libuv/src/unix/core.c:255-261`)

So **the getter is responsible for the zero**: `alloc-zeroed (c-int-size)` —
`foreign-alloc` here is a defect, not a style choice, because uninitialised heap
makes the getter perform a `setsockopt` with garbage — then call, `uv-check`,
`c-int-ref`, and free on every path inside a `guard`, the `tcp.sls:150-165`
shape. The setter allocates, `c-int-set!`s `n`, calls, frees on every path.

A handle kind outside the platform's supported set answers `UV_ENOTSUP`
(`unix/core.c:248-254`); a handle with no fd answers `UV_EBADF`.

**Version floor: satisfied with room.** `uv_stream_get_write_queue_size` is
1.19.0 (`docs/src/stream.rst:256`); `uv_send_buffer_size` / `uv_recv_buffer_size`
are **0.11.29** (`vendor/libuv/ChangeLog:5367,5377`); `uv_tcp_getpeername`
predates both. Floor is 1.44.0 (`Makefile:57-59`). No `check-pins` movement.

## 6. The read-buffer sizing contract, documented

v0.5 does not change this contract; it documents it, because it is currently
discoverable only by reading `ensure-read-buffer!`.

- Allocated by the **first** `uv-read-start!`; freed **only** by the close
  dispatcher (`handles.sls:990`, `:1009-1016`).
- Size **fixed by that first call, irreversibly**. A later differing explicit
  size raises `'buffer-size-fixed`. A caller wanting a different size closes the
  handle.
- A re-start that **omits** the size is always accepted — what makes
  `uv-read-stop!` → `uv-read-start!` the cheap operation read-side backpressure
  needs.
- **Sizing guidance, stated as a tradeoff rather than a recommendation**, since
  §10 has not run: a smaller buffer cuts per-connection foreign memory linearly
  and raises `read(2)` count and `on-data` delivery count — and therefore Scheme
  bytevector allocation (`handles.sls:939`) — proportionally. 64 KiB is libuv's
  own `alloc_cb` suggestion (`unix/stream.c:1050`) and the current default.
  Connection-count-dominated workloads should measure before choosing lower.
- **Hazard, documented for the first time:** `uv-read-stop!` goes through
  `require-open-stream` while `read-dispatch` deliberately tolerates a
  `'closing` handle (`handles.sls:897-900`, code at `:915-922`). A stop issued
  from inside `on-data` for a delivery that raced a close therefore *raises*.
  Guard with `uv-handle-open?` — `test-echo.sps:333-339` shows the shape, there
  guarding a re-start rather than a stop; the hazard and the guard are the same.

## 7. Vendor facts (pinned libuv v1.52.1)

Numbered so §10 and Appendix A can answer by identifier. **V1 and V2 are
source-read, not measured**; D5's tripwire is the compensating control.

### 7.1 V1 — `alloc_cb` and `read_cb` are a synchronous pair, both platforms

- **Unix.** `uv__read`'s `uv_buf_t` is stack-local to the frame; `alloc_cb` and
  `read_cb` are both called from inside it (`unix/stream.c:1043-1053`, normal
  path `read_cb` at `:1145`).
- **Windows TCP.** `uv__tcp_queue_read` posts a **zero-byte** overlapped
  `WSARecv` against static `uv_zero_` (`win/tcp.c:557-577`). The real read at
  `win/tcp.c:1096-1116` is a **non-overlapped** `WSARecv` bracketed by
  `alloc_cb` and `read_cb`.
- **Windows pipe.** `uv__pipe_read_data` posts an overlapped `ReadFile` into
  `buf.base` but never returns with it outstanding: `CancelIoEx` plus a blocking
  `GetOverlappedResult(..., TRUE)` drains it first (`win/pipe.c:2000-2013`).

**Therefore both overlapped-model comments are wrong** for the handle kinds this
binding supports — `stream.sls:187` and, identically, `handles.sls:1001`.

**The rule they produce is still correct**, for a portable reason neither
states: the infallible-alloc invariant (`handles.sls:846-858`). Freeing anywhere
but close means `alloc-dispatch` might have to allocate, or `ensure-read-buffer!`
might realloc on a path libuv can call into. D5 keeps the rule and restates the
reason at both sites, retaining as a footnote that `uv_pipe_t`'s `CancelIoEx`
result is checked only through an `assert` release builds compile out
(`win/pipe.c:2006-2007`) — thin, but not nothing, and unrunnable today (no
Windows CI, ADR-0004).

**D5's tripwire, corrected.** The first draft asserted `UV_HANDLE_ZERO_READ` is
assigned in exactly one place; it is assigned in **two** — `win/tcp.c:559` and
`win/udp.c:280` — so that assertion would have failed `make check-pins`
immediately. The tripwire instead asserts, over `vendor/libuv/src/`:

- `UV_HANDLE_ZERO_READ` assigned in exactly **two** places, one of them
  `win/tcp.c`, and **cleared nowhere**;
- `read_buffer` (`include/uv/win.h:444`) never assigned.

Failure names **both** Scheme comment sites as the thing to re-verify.
Missing-submodule behaviour follows `Makefile:209`; the `## ` help text
(`Makefile:195`) is updated in the same edit. Watched to fail by adding one
assignment to a scratch copy of the vendored tree. The tripwire binds the
**vendored** path only — ADR-0001's system-libuv path is unaudited — and the
rule rests on the portable infallible-alloc invariant regardless.

### 7.2 V2 — the `uv__read` loop reuses the buffer within one iteration

`unix/stream.c:1043` is a `while` loop: `alloc_cb` → `read()` → `read_cb`, then
**again** unless the read did not fill the buffer (`:1147-1155`), bounded by a
32-iteration starvation cap (`:1033-1036`). On a busy socket the buffer is
overwritten immediately after `on-data` returns.

### 7.3 V3 — why a shared per-loop buffer stays rejected

Five independent skeptics, each defaulting to "refuted". The *mechanism*
survived unanimously: the bytes are dead the instant `read_cb` returns, and the
nested-`uv-run` corruption path does not exist (`loop.sls:117` refuses re-entry;
`copy-out` is an operand at `handles.sls:939`, so the fresh bytevector
materializes before user code runs).

The *conclusion* failed on two **structural** grounds — not timing, therefore not
anything a measurement could move:

1. **Per-handle size is public contract.** Two live streams on one loop hold
   different sizes: `sclient` at an explicit 4096 (`test-tcp.sps:1241-1244`) and
   `s-peer` at the default (started size-less at `:1227`), with
   `(live-count 'read-buffer)` = 2 asserted at `:1246-1247`.
2. **The free site is per-handle and fires mid-run.** `close-dispatch`
   (`handles.sls:990`) frees while other streams on that loop are still reading;
   `test-echo.sps:417-418` asserts 16 concurrent read buffers, closing from
   inside callbacks.

Conditions on any future attempt: **Appendix A**, in this repo.

### 7.4 V4 — what each ownership model costs zero-copy

Carried into ADR-0009's amendment. **v0.5 forecloses nothing here**, and the
spec should say so directly: the copied `uv-write!` contract can stay stable
while future work adds vectored writes, `uv_try_write`, borrowed/pinned writes,
callback-scoped borrowed reads, and eventually retained reads under an explicit
lifetime protocol.

- **Borrow-for-the-callback zero-copy** — hand back a sub-range; the caller must
  consume or copy before returning. Works **identically** under per-handle and
  per-loop ownership: by V2 the buffer is reused immediately after `on-data`
  returns, so the usable lifetime is "during the callback" in both. This is what
  ADR-0009's `(bv start end)` span shape reserves, and no ownership model
  forecloses it.
- **Retain-across-callbacks zero-copy — possible, but *not* solved by read-stop
  alone.** `uv-read-stop!` stops the *read loop* from overwriting the buffer
  (V2), which the first draft correctly established. It does **not** stop
  `uv-close!`: `close-dispatch` calls `free-read-buffer!` unconditionally
  (`handles.sls:990`) before the handle is torn down, so a retained span is a
  use-after-free the instant the handle closes — and close can be initiated from
  anywhere, including a teardown sweep. A future retained-borrow design
  therefore needs **explicit borrow ownership**: a borrow token or refcount, a
  deferred close, or another rule coordinating close against outstanding
  borrows. "Machinery that already exists" was wrong.
- **Blast radius of a violated contract.** Per-handle: stale bytes from the
  caller's own connection — contained. Per-loop: another connection's bytes —
  cross-connection disclosure, on a platform with no CI lane. A stronger
  argument for per-handle ownership than the zero-copy one.

## 8. GC and memory invariants (delta)

- No new `lock-object` traffic; the **thirteen** static trampolines
  (`native.sls:991-993`) remain the only locked objects (ADR-0008, as amended at
  v0.2/v0.3/v0.4).
- No new allocation class, so `live-counts`' frozen twelve-element literal
  (`test-native.sps:1200-1204`) is unchanged.
- **`uv-stream-write-queue-size` alone is allocation-free.** The other five each
  allocate — the four buffer-size procedures each own an `int` cell,
  `uv-tcp-peer-address` a `sockaddr_storage` plus an in-out length — so the
  "validate before the first allocation" rule binds all five, and each frees on
  every path out of a `guard`.

  **Each needs its own exercised failure path.** The first draft claimed one
  `'ENOTCONN` row covered all five; it covers `uv-tcp-peer-address` only. §13.3
  requires, per wrapper: native-failure cleanup, closed/closing gate behaviour,
  setter validation *before* allocation, and the success path. Five wrappers,
  four rows each — this is the bulk of the suite, and the memory lane has
  nothing to walk without it.

## 9. Connection ownership above the binding

The production concern that motivated this milestone is per-connection cost at
scale, which the layer above cannot manage without tracking connections. **No
binding-owned connection table is needed or wanted.** What the binding owes is
documentation of one hazard that makes the upper-layer protocol non-obvious:

> **A second `uv-close!` silently discards its callback.** `real-close-handle!`
> guards on `(eq? (handle-state handle) 'open)` (`handles.sls:1128`), so a close
> issued against an already-`'closing` handle stores nothing and the supplied
> `on-close` never runs.

That goes in `docs/api.md` beside the existing "Exit ≠ close" note. Its
consequence for a server — deregistration must not ride on a close the owner did
not initiate — is server-layer design and belongs in
`.plans/chez-http-server-architecture.md`, which v0.5 cites rather than
restates. The protocol in brief, recorded there: capture peer identity
immediately on accept, register before the first read, centralize *all* close
initiation through the owner, deregister only from the first `on-close`, and
optionally reconcile against `uv-loop-live-handles` (`loop.sls:157`).

`chez-websocket` dependencies are unchanged from the first draft and remain in
its own spec; the one binding-side note is that **graceful close is
`uv-shutdown!`, never `uv-close!`** — the latter flushes the queue with
`UV_ECANCELED` (`unix/stream.c:454,464`) and a Close frame never reaches the
wire.

## 10. Stage 0 spike (`spike/flow/`, findings in `spike/flow/FINDINGS.md`)

**Q1 — what should the read-buffer default be?** The first draft asked only for
bytes-per-read and syscalls-per-MiB, which measures one side of a three-way
tradeoff. The full set, at 4096 / 16384 / 65536:

- peak RSS after first-read allocation, at representative connection counts;
- connection setup and `uv-read-start!` cost;
- `on-data` deliveries **and Scheme bytevector allocations** per MiB — the term
  the first draft omitted entirely, and the reason 16384 is no longer proposed;
- throughput and CPU on bulk traffic;
- one mixed small-message/bulk fairness measurement.

This keeps every size a candidate until evidence selects one. The follow-up
milestone that changes the default cites this and carries its own ADR.

**Q2 — what does `SO_RCVBUF` actually cost per connection?** Measured on both
platforms at the autotuned default and at a set value, since §1 asserts this may
exceed the read buffer and that assertion is currently arithmetic, not
measurement.

**Prerequisite:** any high-N leg needs `ulimit -n` raised — macOS's default soft
limit is far below what 1,000 loopback pairs require, and the failure is
`EMFILE`, which reads as a libuv bug. FINDINGS records achieved-vs-attempted N
per platform. Committed fixtures cap N independently of the spike's, since every
suite joins the Valgrind lane at whatever N it uses.

**Linux mechanism** follows v0.4's: temporary spike-branch workflow (`ci.yml`
fires only on push to `main`), run id in FINDINGS, branch deleted after harvest.
Scripts continue the repo-wide sequence (`spike/flow/13-…`; existing run 00–12),
with a `spike/flow/.gitignore`.

## 11. ADR-0018 — no bounded write queue in the binding

**Rejected.** The binding will not hold unsubmitted write blocks, will not
enforce a queue-depth or byte cap, and `uv-write!` will not refuse. Two
structural reasons, both of which the binding would own as bugs:

1. **Ordering.** `uv-shutdown!` submits immediately (`stream.sls:110-119`). A
   shutdown issued after a deferred write would reach libuv *first*, putting FIN
   ahead of data.
2. **Teardown.** `uv-close!` frees the read buffer and the handle pointer and
   nothing else (`handles.sls:984-996`); libuv cannot cancel what it was never
   given. Someone must free every unsubmitted block and invoke every
   `on-complete`, on a path that has no such step and no test.

And the property it forfeits: a consumer producing without limit grows a
*Scheme-side* queue instead of a foreign one — invisible to `live-counts` and to
both teardown sweeps (`handles.sls:500, 508`) — so the OOM arrives anyway with
one more layer between cause and symptom.

Also rejected, more cheaply: a **caller-declared, binding-enforced limit**
(`uv-stream-set-write-limit!`). Its default is a no-op, so it is genuinely
opt-in and can be added later without breaking anything — which is exactly why
it should be added later, if a real consumer asks. Adding it now would amend a
promise made in `README.org:19-21` on speculation.

Queueing and admission remain server policy.

## 12. Deferred, with reasons

### 12.1 Release-build allocation counters — own milestone

`src/libuv-shim.c:290-292` compiles every `chez_uv_live_*` to a constant `0`
outside a debug build. Note the counter is an **allocation count**, not a
foreign-memory measurement — §4.1's arithmetic applies to it too. Deferred
because:

- **As a rider it would not achieve its own goal.** The only Scheme accessor is
  `live-counts`, exported from `(libuv private native)`. Without a public
  accessor and a facade row, an operator still cannot read it without importing
  a private library — the thing the facade exists to prevent
  (`check-prod.sps:40-42`).
- **It restructures `check-prod`,** whose pass condition is a single
  `(for-all (lambda (p) (zero? (cdr p))) during)` over every class
  (`check-prod.sps:77`). Making one counter real turns a correct release
  artifact into a FAIL. Both CI negative guards
  (`.github/workflows/ci.yml:258,357`) must still fail.
- **Unpriced concurrency.** `live_write_req` is a plain `long` with
  unsynchronized `+= 1` / `-= 1` (`libuv-shim.c:218,240-242`), and
  `libuv-shim.h:41-44` calls the counters "single-threaded test use only."

Four sites go stale with it: `check-prod.sps:16-19`, `Makefile:545-547`,
`docs/building.md:80-93`, `src/libuv-shim.h:41-44`.

### 12.2 `orphan-events` cap — hygiene PR, no version bump

`handles.sls:682-688` is an uncapped `cons` + `reverse`. Real motivation, no
relationship to flow control, and a cost this milestone should not absorb: seven
rows across four suites index it with `(list-tail (orphan-callback-events) before)`,
and `test-timer.sps:821` asserts a **zero delta** in `length` — which a saturated
log satisfies unconditionally, silently emptying a meaningful assertion.

For that PR: a **bounded prefix log**, not a ring, retaining first-N *and*
last-M (a defect beginning after hours of uptime finds a full log and is
otherwise only an anonymous increment), with the dropped count keyed per orphan
kind, a monotonic total-recorded counter, the delta-style rows re-pointed at the
total, and its own test using accessors directly, never `list-tail`.

## 13. Testing strategy

Harness rules restated as obligations: SRFI-64, every suite ends with its own
`(exit …)`, iteration caps never wall-clock, sentinels never `#f`/`0`, every new
assertion watched-to-fail against a mutation logged in
`.plans/flow-stage-N-mutation-log.md`.

### 13.1 The default-size pin (D1)

**No test pins the default today.** Every `stream-read-buf-len` assertion is
against an explicit 4096 (`test-tcp.sps:1244`, `:1275`, `:1285`), a hand-set 64
(`:774`), or self-comparing (`:1385`) — and `test-tcp.sps:1239-1240` says so:
*"the sizes here are this suite's own rather than the default."*

Add it against unchanged code: on a fresh connected handle, start a read with
the size **omitted** — the only path reaching the default — and assert
`(stream-read-buf-len h)` equals 65536. Watch it fail by setting the constant to
65535 in a scratch copy.

Since v0.5 no longer changes the default, this row's whole value is forward:
it is what makes the follow-up milestone's change a deliberate, reviewed edit
instead of a silent one.

### 13.2 The congestion fixture (D2)

A gauge test observing only `0` passes against a stub, a misbound pointer, and a
`size_t` marshalling bug — and `0` is truthy. Observe a **positive** value, then
observe it **fall**.

- **Determinism.** Shrink **both** `SO_SNDBUF` and the peer's `SO_RCVBUF` after
  accept — shrinking only the writer's does not bound loopback buffering, since
  the receive buffer absorbs independently and Linux doubles and floors.
- **Procedure.** Hold the peer **unread** while writing fixed-size chunks in an
  iteration-capped loop until the gauge reads positive, with
  `'gauge-never-went-positive` as the named exhaustion failure. Then start
  reading on the peer and drain until every completion has fired *and* the gauge
  reaches zero. Sample the positive value synchronously after `uv-write!`
  returns and before any `uv-run` (`stream.sls:100-104` submits inline).
- **Two mutations, one per assertion.** Constant `0` breaks the positive row; a
  constant non-zero (4096) breaks the fall row.
- **Per-stream discrimination.** A third idle stream on the same loop reads `0`
  at the instant the congested one reads positive, as one
  `'(congested-positive idle-zero)` row — the only row separating per-stream
  from per-loop or from a misbound pointer.
- **The gate**, mutated on a **closing** stream, per §4.1.
- **Windows.** Qualify or separately cover; upstream's own positive-queue test is
  skipped there, and §4.1's contract differs by platform.

### 13.3 The buffer-size wrappers (D3)

Per wrapper — getter and setter, send and receive — four rows:
native-failure cleanup, closed/closing gate, setter validation *before*
allocation, success path. Twenty rows, and §8 explains why fewer will not do.

**The zero-seed proof needs care.** "Call the getter twice, assert no change"
does **not** prove zero-initialisation: a broken getter seeding `1` performs the
same `setsockopt(1)` twice and returns the same value both times. The
discriminating row is a setter/getter sequence at a **constrained modest value**
— set to a known `n`, read back, assert the read is consistent with `n` and
*not* with the seed a broken getter would write — or a small test seam exposing
the cell's pre-call contents. Choose one and state it in the plan; the naive row
is an empty test.

Setter direction: assert `(< after before)` against the value read *before* the
set. `(<= n after)` is satisfied by a no-op setter leaving the large default.

### 13.4 Cross-stream isolation (the forward guard)

**No current test asserts that closing one stream leaves others on the same loop
reading successfully.** Write it against the current design, where it passes, so
Appendix A's conditions are guarded by a test rather than prose.

N readers on one loop; close one from inside its own callback. **Gate the
post-close writes** on `(eq? 'closed (uv-handle-state closed-one))` via an
iteration-capped tick, asserted as its own row — `close-dispatch` frees on a
*later* loop iteration than the `uv-close!` call (`handles.sls:984-996`), so a
write issued at close-*issue* time can complete before the window opens.

Then assert every survivor completes a subsequent read with a **per-survivor
distinct** sentinel, plus a pairwise-distinctness row: `test-echo.sps:163-172`
records by name why one shared sentinel is not enough — a cross-wired binding
hands every survivor the same sentinel and every row goes green. Compare with
`compare-bytes`. Assert the closed stream's delivery count is unmoved.

**Mutation, in `src/`:** make `alloc-dispatch` resolve the most-recently-registered
stream instead of the pointer libuv handed it (`handles.sls:884`). Deleting a
survivor's `uv-read-start!` proves only that the fixture is wired up.

**Scope limit:** the payload rows catch the nulled-field/`UV_ENOBUFS` cascade
everywhere; the free-memory-others-hold mode is a use-after-free that usually
reads back correct bytes and is caught only under `make test-memory` on the
Linux leg (ADR-0003).

### 13.5 Peer address, and what is deliberately not asserted

`uv-tcp-peer-address`: assert **both directions** — the client's peer port equals
the server's listening port, and the accepted handle's peer port equals the
client's `uv-tcp-getsockname-port`. The second is the only thing catching an
implementation that returns the *local* address, and two independent ports
shrink the byte-order blind spot (`tcp.sls:125-129`) from ~1/256 to ~1/65536.
**Require the expected IPv4 string**, not a tolerated `#f`. Row shape
`(let-values (((a p) …)) (list a p))` against a list — a raise inside a bare
`test-assert` becomes `#f`. Plus `'ENOTCONN` on a bound-but-unconnected handle
(`test-tcp.sps:1249-1254` shape).

**Not asserted:** head-of-queue drain makes two consecutive `uv-write!` calls
non-interleaving *structurally*, so "the byte stream is never interleaved" is an
absence assertion no mutation can break. It is a consequence of V2's
head-of-queue drain (`unix/stream.c:1043`), stated here with that citation and
logged in the mutation log as an explicitly uncovered property with the reason,
per AGENTS.md. It is **not** a §10 spike question — there is nothing to measure
about a structural guarantee. The v0.5 assertion
scoped to what the binding owns: accumulated bytes equal payload-A then
payload-B, **and** both `on-complete`s fired with `'no-error` in submission
order — that one fails if completions are routed by kind instead of block
pointer.

`test-native.sps` carries `size_t` and int-out-param round-trips at stub level.
`make test-memory` green: per ADR-0003 the Linux Valgrind leg is the sole memory
gate and the only thing catching §13.4's use-after-free mode and §8's five
wrappers leaking on a failure path.

## 14. Milestone sequence

1. **Stage 0** — spike `spike/flow/`, Q1 and Q2, `FINDINGS.md` with commands.
2. **Stage 1** — §13.1's default pin and §13.4's isolation regression, both
   against unchanged code, both watched to fail. Nothing in `src/` changes.
3. **Stage 2** — the implementation plan, written and **adversarially reviewed
   before any `src/` change**, per AGENTS.md: a plan's code blocks are executable
   spec, and §5.1's four `foreign-procedure` forms plus §5.1's alloc-zeroed
   discipline have had no such pass.
4. **Stage 3** — D2 binding; §13.2.
5. **Stage 4** — D3 bindings in `(libuv handle)`; §13.3's twenty rows.
6. **Stage 5** — D4; §13.5.
7. **Stage 6** — D5: both comment sites, the corrected two-assignment tripwire
   and its help text. ADR-0018. ADR-0009's dated amendment. Appendix A into the
   repo.
8. **Stage 7** — D6 version bump, CHANGELOG (all **Added**), README ADR count
   17 → 18 and status line, `docs/api.md`: six rows, reason symbols, the
   three-buffers table, the sizing tradeoff, the `uv-close!` callback-drop
   hazard. Full `make test` + `make test-memory` + `make check-prod`,
   whole-branch review, squash merge, annotated tag `v0.5.0`, closing ritual.

Stage 1 precedes Stage 2 deliberately: both tests exist and are watched-to-fail
before a plan is written against them. Stage 2 precedes every `src/` change.

## Appendix A — conditions on any future shared-buffer design

§7.3 rejects a shared per-loop read buffer. Recorded here rather than in a
review transcript, because a transcript is not in the working tree. Three are
now **guarded by tests** — marked ✔.

1. **Resolve the size contract first.** Either remove `buffer-size` from
   `uv-read-start!` as a documented breaking change, or re-specify it as
   loop-scoped. Silently ignoring a caller's size is not permitted. ✔ §13.1 plus
   `test-tcp.sps:1241-1247`.
2. **If per-handle sizing survives**, the shared buffer is sized at the max ever
   requested on that loop, never shrinks, and grows only outside a callback
   frame.
3. **Move the free off the close path.** ✔ §13.4.
4. **Establish a loop-lifetime free site and record why it is safe** — the
   argument replaces the stated rule at `handles.sls:1003-1007`.
5. **Key the buffer on the loop record, never module-global.** `uv-run`'s
   re-entry guard is per-loop (`loop.sls:117`), so `on-data` under loop A may
   legally call `(uv-run loop-B 'nowait)`.
6. **`alloc-dispatch` stays infallible and allocation-free.** The unresolvable
   arm must still answer `(0,0)` so `unix/stream.c:1050-1053`'s bounded
   `UV_ENOBUFS`-and-return survives. ✔ `test-tcp.sps`'s orphan-read row.
7. **Gate on an explicit handle-kind allowlist (`'tcp`, `'pipe`) that fails
   closed.** `uv_tty_t` genuinely retains the buffer across a threadpool
   boundary (`win/tty.c:616,631`); `uv_udp_t` slices one `alloc_cb` across N
   datagrams (`unix/udp.c:256,277`).
8. **Make "copy-out completes before `on-data` is entered" a stated, tested
   invariant.** Today it is argument-evaluation order at `handles.sls:939`.
9. **Coordinate close against outstanding borrows.** Independent of sharing, and
   required by *any* retained-borrow design: `close-dispatch` frees the buffer
   unconditionally (`handles.sls:990`), so read-stop alone does not make a
   retained span safe. Needs a borrow token, refcount, deferred close, or
   equivalent (§7.4).
10. **Supersede or retire ADR-0009's zero-copy reservation**, weighing §7.4's
    retained-borrow loss and the cross-connection blast radius.
11. **Extend D5's tripwire** to gate the shared buffer on the libuv pin.
12. **Re-specify the S10 counters** as per-loop, treating the rewrite of
    `test-echo.sps:417-418` (16) and `test-tcp.sps:1246-1247` (2) as the signal
    it is: a semantic change, not a transparent optimisation.
13. **Document the single-thread requirement.** The handle registry
    (`handles.sls:485`) is an unsynchronised `eqv-hashtable`.
