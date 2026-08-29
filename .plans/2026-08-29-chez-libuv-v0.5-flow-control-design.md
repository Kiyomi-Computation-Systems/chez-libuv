# Design Spec: chez-libuv v0.5 — Flow Control Mechanism

Status: **Draft** (five-lens adversarial review folded in 2026-08-29; awaiting
maintainer approval and the Stage 0 spike)
Date: 2026-08-29
Branch: `feat/v0.5-flow-control`

v0.5 adds no new libuv subsystem. It closes a gap the first four milestones
left open: **chez-libuv's per-connection memory floor is fixed at a number
chosen for throughput, and its write side offers no congestion signal at all.**
Both are mechanism problems, and both are fixable without the binding acquiring
a line of connection-state or backpressure *policy*.

Driving use case: a WebSocket or HTTP server holding 1,000–10,000 concurrent
connections on one loop. One number motivates the milestone:

- **625 MiB.** Ten thousand streams × the 65536-byte per-handle read buffer
  (`src/libuv/stream.sls:136`), allocated on the first `uv-read-start!` and
  held until close, before a single byte is read or written.

The layer above can already bound its own write memory *exactly* — `uv-write!`
allocates one block per request (`stream.sls:85-92`), every completion is
guaranteed to arrive (`handles.sls:782-785`), so an increment at submission and
a decrement in `on-complete` is not an estimate. What it cannot do is size the
read buffer after the fact, or distinguish "the peer stopped reading" from "I
just submitted a lot." Those two are this milestone.

## 1. Goal and non-goals

**Goal.** Move the per-connection memory floor to a number chosen for
connection count rather than throughput, and give the consumer the one
congestion quantity it cannot derive. Nothing here refuses or queues. **The one
thing this milestone decides is a default**, and that decision gets its own
record (ADR-0019) rather than riding in as a constant change.

**Non-goals.**

- **No bounded write queue in the binding.** Rejected with reasons recorded in
  ADR-0018 (§10). This is the option the milestone exists to decline.
- **No shared per-loop read buffer, and no spike to reconsider one.** ADR-0009
  already decides per-handle ownership in words; §7.3 records *why* that
  decision survives adversarial attack, on two structural grounds no
  measurement can move. ADR-0009 gains a dated amendment carrying §7.2 and
  §7.4; Appendix A carries the conditions any future attempt must satisfy.
- **No zero-copy reads.** ADR-0009 stands. §7.4 records what each ownership
  model costs zero-copy, because the amendment must say it.
- **No release-build allocation counters.** Deferred to its own milestone; see
  §11.1 for why it does not fit here.
- **No `orphan-events` cap.** Deferred to a hygiene PR; see §11.2.
- **No admission control.** An accept cap dominates every per-connection bound
  arithmetically, and no binding change can provide one. Server-layer policy.
- **No WebSocket anything.** `chez-websocket` is a separate project with its own
  spec. §9 records only which v0.5 surfaces it depends on, so this milestone is
  validated against a real consumer rather than a guess.
- **No new library module.**

## 2. Decisions summary

| # | Decision | Rationale |
|---|---|---|
| D1 | `default-read-buffer-size` 65536 → **16384**, recorded in **ADR-0019** | 625 MiB → 156 MiB at 10k streams. Not 4096: below a batched read, costs syscalls on real traffic. A behaviour change for every caller who never passed a size, so it gets a decision record and a CHANGELOG **Changed** entry, not a tweak. Revisable by §10's Q1. |
| D2 | Bind `uv_stream_get_write_queue_size` as a **congestion** signal | The one quantity Scheme cannot derive. Documented as *not* a memory gauge (§4.1). |
| D3 | Bind `uv_send_buffer_size` / `uv_recv_buffer_size`, in `(libuv handle)` | Required to test D2 deterministically — a prerequisite, not a convenience. Lands handle-generic per ADR-0014's precedent, since the native accepts TCP, pipe and UDP. |
| D4 | Bind `uv_tcp_getpeername` | Completeness of the mirror: a binding with `getsockname` and no `getpeername` is incomplete, and there is no Scheme substitute. |
| D5 | Correct **both** overlapped-model comments; add a `check-pins` vendor tripwire | The stated mechanism is dead code for the bound handle types (§7.1). Under AGENTS.md's "prefer a check to a comment", the replacement is a check. |
| D6 | Version → 0.5.0 in `Akku.manifest` **and** `CHANGELOG.md` together | `check-pins` fails otherwise (`Makefile:226-237`). |

## 3. Blast radius

No new library. Every file that changes, and why.

```
src/libuv/stream.sls          D1 (constant), D2 (uv-stream-write-queue-size), D5
src/libuv/handle.sls          D3 (four procedures)
src/libuv/tcp.sls             D4; re-exports D2 and D3
src/libuv/private/native.sls  four foreign-procedure bindings + exports
src/libuv/private/handles.sls D5 (the second overlapped comment, :1001)
src/libuv.sls                 facade: six new names
Makefile                      D5 tripwire + its `## ` help text (:195)
README.org                    ADR count 17 → 19; version status line
CHANGELOG.md, Akku.manifest   D6
docs/api.md                   six export rows, the uv-read-start! default,
                              new reason symbols (:286-294), Flow control section
.plans/decisions/0018-*.md    ADR-0018 (§10)
.plans/decisions/0019-*.md    ADR-0019 (D1)
.plans/decisions/0009-*.md    dated amendment (§7.4)
tests/test-tcp.sps            the default pin (§12.1), peer-address rows
tests/test-facade.sps         six exercised exports; needs a connected pair
tests/test-native.sps         size_t and int-out-param round-trips at stub level
tests/test-flow.sps           NEW: congestion fixture, cross-stream isolation
spike/flow/                   Q1 (§10), FINDINGS.md, .gitignore
```

Any new suite is auto-discovered by the `TESTS` wildcard and auto-enrolled in
the Valgrind lane via `MEMORY_TESTS := $(TESTS)`. It must **never** be added to
`PURE_TESTS` — `test-flow.sps` imports native code.

## 4. Public API

### 4.1 `uv-stream-write-queue-size`

```scheme
(uv-stream-write-queue-size stream) → exact non-negative integer
```

Bytes libuv has queued for this stream and not yet handed to the kernel. Gated
by `require-open-stream` (`stream.sls:39-43`).

**The native read cannot fail; the gate can**, on a closed or closing handle —
so `&uv-handle-closed` is part of this procedure's contract and gets its own
row (§12.2). Without that row, deleting the gate is a silent mutation:
`close-dispatch` zeroes the pointer (`handles.sls:989-994`), and a read through
`0` returns a plausible number rather than faulting.

`size_t`, not a signed type, and that is deliberate. This repo has a scar here:
binding `nread` unsigned routed `UV_EOF` into the data path as four gigabytes
of data (`handles.sls:889-895`). The queue size is the opposite case — it
cannot be negative and the call cannot fail — so `size_t` is correct and the
trap was considered.

**Two things the documentation must state, because neither is guessable:**

1. **This is not a memory gauge.** It decrements as the kernel accepts bytes
   mid-request (`vendor/libuv/src/unix/stream.c:693-694`) while the
   `foreign-alloc` block stays allocated until the whole request completes. It
   *undercounts* the memory the binding holds. For memory, count submissions
   against completions in the consumer — that number is exact.
2. **A stuck non-zero value can mean the stream errored, not that the peer is
   slow.** libuv deliberately leaves the count non-zero after a failed write so
   the user stops writing (`unix/stream.c:719-724`, verbatim comment). The two
   cases are distinguished only by the status delivered to `on-complete`, so
   this value must never be read alone.

### 4.2 `uv-send-buffer-size`, `uv-recv-buffer-size` and setters

```scheme
(uv-send-buffer-size handle)     → exact positive integer
(uv-send-buffer-size! handle n)  → unspecified
(uv-recv-buffer-size handle)     → exact positive integer
(uv-recv-buffer-size! handle n)  → unspecified
```

**Handle-generic, in `(libuv handle)`, re-exported from `(libuv tcp)`.** The
native takes `uv_handle_t*` and accepts TCP, pipe and UDP
(`vendor/libuv/src/unix/core.c:248-254`). ADR-0014 exists because this repo
already paid once for TCP-shaping a native that was not TCP-specific; that
lesson applies verbatim. The gate is a kind allowlist that fails closed, so
adding a handle kind without revisiting this breaks a test rather than a
comment.

libuv overloads one entry point on whether `*value` is zero (get) or non-zero
(set). That overload is a C calling convention, not an API worth mirroring —
the binding splits it, because a getter that silently becomes a setter when
handed the wrong integer is exactly the kind of trap a "legible mirror" should
be legible about. §12.2 carries the row that proves the split holds.

The setter validates `n` **exact, positive, and below 2^31** before the call,
raising `&uv-invalid-argument` with reason `'buffer-size-out-of-range`.
`c-int-set!` bottoms out in `foreign-set! 'int` (`native.sls:727-732`), which
raises a raw Chez exception outside the condition hierarchy for a value that
does not fit — so the range check is what keeps the failure inside the
documented vocabulary.

Platform note for the docs: the kernel may round or double the requested value
(Linux doubles it), so a get after a set is not required to return `n`. Tests
assert a **direction relative to the value read before the set**, never
equality — and never merely `(<= n after)`, which a no-op setter satisfies.

### 4.3 `uv-tcp-peer-address`

```scheme
(uv-tcp-peer-address tcp) → (values address-string-or-#f port)
```

`uv_tcp_getpeername`, reusing `sockaddr->address-string` (defined
`native.sls:552`, exported `:94`) and the `sizeof-sockaddr-storage` /
in-out-length discipline already written for `uv-tcp-getsockname-port`
(`tcp.sls:148-165` — the full range, including the port read and the paired
`free!`s, which is the half most worth copying). The `(values address port)`
shape is governed by ADR-0012.

**Failure contract, stated because the sibling's is:**
`sockaddr->address-string` answers `string | #f` deliberately, so the first
value may be `#f` and callers must handle it. An unconnected handle answers
`UV_ENOTCONN` through `uv-check`. A namelen too short for a port raises
`&uv-invalid-argument` with reason `'sockaddr-too-small-for-a-port`, matching
the sibling.

**Deliberate asymmetry, recorded so it is not read as an oversight:** the local
side exposes only `uv-tcp-getsockname-port`, because what a caller needs
locally is the ephemeral port a zero-bind chose. What a caller needs about the
peer is the address. `uv-tcp-sockname-address` on symmetry grounds alone is
deferred until something needs it.

*What a consumer builds with this — per-IP connection limits, access logging —
is illustration, not motivation. The cap itself never enters the binding.*

### 4.4 Facade

**Six** names join `src/libuv.sls`: `uv-stream-write-queue-size`,
`uv-send-buffer-size`, `uv-send-buffer-size!`, `uv-recv-buffer-size`,
`uv-recv-buffer-size!`, `uv-tcp-peer-address`.

`tests/test-facade.sps` is the suite whose *purpose* is the re-export list
(`src/libuv.sls:19` begins it; the write-it-out-by-name rationale is at
`:14-17`). Each of the six must be **exercised** there, not asserted about: the
suite's enforcement is an expand-time unbound identifier
(`test-facade.sps:19-23`), so a `(test-assert "… is re-exported" (procedure? …))`
row enforces nothing and is the truthiness trap besides. The two setters need a
connected pair — a fixture that suite does not have today, whose TCP work is a
bind-and-read-port at `:294`. Budget it.

## 5. Internals

### 5.1 native.sls — four bindings

```scheme
(define uv-stream-get-write-queue-size
  (foreign-procedure "uv_stream_get_write_queue_size" (uptr) size_t))
(define uv-send-buffer-size
  (foreign-procedure "uv_send_buffer_size" (uptr uptr) int))
(define uv-recv-buffer-size
  (foreign-procedure "uv_recv_buffer_size" (uptr uptr) int))
(define uv-tcp-getpeername
  (foreign-procedure "uv_tcp_getpeername" (uptr uptr uptr) int))
```

`size_t` is already proven here (`native.sls:371-373`). All four are defined
after `load-shared-object` — a `foreign-procedure` resolves its entry point at
evaluation, so a misplaced definition fails at *import* time, pointing nowhere
near the mistake (AGENTS.md).

No shim function: ADR-0002 says the shim never wraps a `uv_*` call, and nothing
here needs what the shim provides.

**The `int*` out-parameter is load-bearing.** libuv's get-vs-set discriminator
reads the caller's memory:

```c
len = sizeof(*value);
if (*value == 0)  r = getsockopt(fd, SOL_SOCKET, optname, value, &len);
else              r = setsockopt(fd, SOL_SOCKET, optname, (const void*) value, len);
```
(`vendor/libuv/src/unix/core.c:255-261`)

So **the getter is responsible for the zero**: it allocates with
`alloc-zeroed (c-int-size)` — `foreign-alloc` here is a defect, not a style
choice, because uninitialised heap makes the getter perform a `setsockopt` with
garbage — calls, routes the rc through `uv-check`, reads with `c-int-ref`, and
frees on every path inside a `guard`, exactly the shape at `tcp.sls:150-165`.
The setter allocates, `c-int-set!`s `n`, calls, frees on every path.

All four route rc through `uv-check`. `uv_tcp_init` passes `AF_UNSPEC`
(`vendor/libuv/src/unix/tcp.c:146-148`), so a handle with no socket yet answers
`UV_EBADF` — these are post-connect/post-accept calls — and a handle kind
outside TCP/pipe/UDP answers `UV_ENOTSUP` (`unix/core.c:248-254`).

**Version floor: satisfied with room.** `uv_stream_get_write_queue_size` is
1.19.0 (`vendor/libuv/docs/src/stream.rst:256`); `uv_send_buffer_size` /
`uv_recv_buffer_size` are **0.11.29** (`vendor/libuv/ChangeLog:5367,5377`);
`uv_tcp_getpeername` predates both. The floor is 1.44.0 (`Makefile:57-59`). No
`check-pins` movement.

### 5.2 The read-buffer constant

`default-read-buffer-size` (`stream.sls:136`) 65536 → 16384. One constant.
`ensure-read-buffer!` (`stream.sls:197-205`) is untouched: first call fixes the
size, a later differing explicit size raises `'buffer-size-fixed`, a
size-omitting re-start is always accepted — which is what keeps stop/restart
backpressure free.

Note for ADR-0019: this moves away from libuv's own `alloc_cb` suggestion,
which passes `64 * 1024` (`unix/stream.c:1050`). The binding is a legible
mirror of libuv's *verbs*, not of its buffer sizing hints, but the divergence
should be stated rather than discovered.

## 6. The read-buffer sizing contract, stated

v0.5 does not change this contract; it documents it, because it is currently
discoverable only by reading `ensure-read-buffer!`.

- Allocated by the **first** `uv-read-start!` on a handle; freed **only** by the
  close dispatcher (`handles.sls:1009-1016`).
- Size **fixed by that first call, irreversibly**. A later call naming a
  different size raises `'buffer-size-fixed`. A caller wanting a different size
  closes the handle.
- A re-start that **omits** the size is always accepted. This is what makes
  `uv-read-stop!` → `uv-read-start!` the cheap operation read-side backpressure
  needs it to be.
- **Sizing guidance** (new, `docs/api.md`): 16384 is the default and suits
  many-connections/small-message workloads. Pass 65536 for bulk transfer, 4096
  when connection count dominates. The size is per-handle, so one server may
  size a bulk upload socket and a chatty control socket differently.
- **Hazard, documented for the first time:** `uv-read-stop!` goes through
  `require-open-stream` while `read-dispatch` deliberately tolerates a
  `'closing` handle (`handles.sls:897-900`, code at `:915-922`). A stop issued
  from inside `on-data` for a delivery that raced a close therefore *raises*.
  Guard with `uv-handle-open?` — `test-echo.sps:333-339` demonstrates the shape,
  there guarding a re-start rather than a stop; the hazard and the guard are the
  same.

## 7. Vendor facts (pinned libuv v1.52.1)

Numbered so §10 and Appendix A can answer by identifier. **V1 and V2 are
source-read, not measured**; D5's tripwire is the compensating control.

### 7.1 V1 — `alloc_cb` and `read_cb` are a synchronous pair, both platforms

- **Unix.** `uv__read`'s `uv_buf_t` is stack-local to the frame; `alloc_cb` and
  `read_cb` are both called from inside it (`unix/stream.c:1043-1053`, normal
  path `read_cb` at `:1145`).
- **Windows TCP.** `uv__tcp_queue_read` posts a **zero-byte** overlapped
  `WSARecv` against static `uv_zero_`, never a user buffer
  (`win/tcp.c:557-577`). The real read at `win/tcp.c:1096-1116` is a
  **non-overlapped** `WSARecv` — `lpOverlapped` and `lpCompletionRoutine` both
  NULL — bracketed by `alloc_cb` and `read_cb`.
- **Windows pipe.** `uv__pipe_read_data` posts an overlapped `ReadFile` into
  `buf.base` but never returns with it outstanding: `CancelIoEx` plus a blocking
  `GetOverlappedResult(..., TRUE)` drains it first (`win/pipe.c:2000-2013`);
  `read_cb` runs at `:2019-2023`.

**Therefore both overlapped-model comments are factually wrong** for the two
handle kinds this binding supports — `stream.sls:187` and, identically,
`handles.sls:1001`. `UV_HANDLE_ZERO_READ` is assigned once (`win/tcp.c:559`)
and cleared nowhere; `read_buffer` (`include/uv/win.h:444`) is read and never
assigned. The non-zero-read TCP branch is dead.

**The rule they produce is still correct**, for a reason neither states and
which is *portable*: the infallible-alloc invariant (`handles.sls:846-858`).
Freeing anywhere but close means `alloc-dispatch` might have to allocate, or
`ensure-read-buffer!` might have to realloc on a path libuv can call into. D5
keeps the rule, restates the reason at both sites, and retains as a footnote
that `uv_pipe_t`'s `CancelIoEx` result is checked only through an `assert` that
release builds compile out (`win/pipe.c:2006-2007`) — thin, but not nothing,
and unrunnable today (no Windows CI, ADR-0004).

**D5's tripwire, specified.** `check-pins` asserts exact occurrence counts over
the vendored tree and prints them on success: `UV_HANDLE_ZERO_READ` assigned in
exactly one place under `vendor/libuv/src/` and cleared nowhere; `read_buffer`
never assigned. A vendor bump that adds a clear-site or an assignment fails the
pin with a message naming **both** Scheme comment sites as the thing to
re-verify. Missing-submodule behaviour follows the existing arm at
`Makefile:209`. The `## ` help text (`Makefile:195`) is updated in the same
edit. Watched to fail by adding one assignment to a scratch copy of the
vendored tree. The tripwire binds the **vendored** path only — ADR-0001's
system-libuv path is unaudited, and the rule rests on the portable
infallible-alloc invariant, which does not depend on the vendor fact at all.

### 7.2 V2 — the `uv__read` loop reuses the buffer within one iteration

`unix/stream.c:1043` is a `while` loop: `alloc_cb` → `read()` → `read_cb`, then
**again** unless the read did not fill the buffer (`:1147-1155`, "Save a system
call and return if we didn't fill the buffer"), bounded by a 32-iteration
starvation cap (`:1033-1036`). On a busy socket the same handle's buffer is
overwritten immediately after `on-data` returns.

Load-bearing for §7.4, and not previously written down anywhere.

### 7.3 V3 — why a shared per-loop buffer stays rejected

Five independent skeptics, each instructed to default to "refuted". The
*mechanism* survived unanimously: the bytes are dead the instant `read_cb`
returns, and the nested-`uv-run` corruption path does not exist, because
`loop.sls:117` refuses re-entry and `copy-out` is an operand at
`handles.sls:939`, so the fresh bytevector materializes before user code runs.

The *conclusion* failed on two structural grounds — **not** on timing, and
therefore not on anything a measurement could move:

1. **Per-handle size is public contract.** Two live streams on one loop hold
   different sizes: `sclient` fixed at an explicit 4096
   (`tests/test-tcp.sps:1241-1244`) and `s-peer` at the default (started
   size-less at `:1227`), with `(live-count 'read-buffer)` = 2 asserted at
   `:1246-1247`. One buffer cannot satisfy both.
2. **The free site is per-handle and fires mid-run.** `close-dispatch`
   (`handles.sls:989`) frees while other streams on that loop are still
   reading; `test-echo.sps:417-418` asserts 16 concurrent read buffers, closing
   from inside callbacks. The first disconnect either frees memory fifteen
   others hold, or nulls the field and cascades `UV_ENOBUFS` across unrelated
   connections.

The conditions any future attempt must satisfy are **Appendix A**, in this
repo, not in a review transcript.

### 7.4 V4 — what each ownership model costs zero-copy

Carried into ADR-0009's amendment, because that is where a future zero-copy
milestone will look.

- **Borrow-for-the-callback zero-copy** — hand back a sub-range; the caller must
  consume or copy before returning. Works **identically** under per-handle and
  per-loop ownership: by V2 the buffer is already reused immediately after
  `on-data` returns, so the usable lifetime is "during the callback" in both.
  This is the flavor ADR-0009's `(bv start end)` span shape reserves, and no
  ownership model forecloses it.
- **Retain-across-callbacks zero-copy** — `on-data` hands back a span; the caller
  calls `uv-read-stop!` to freeze it (`uv_read_stop` nulls `read_cb`, so V2's
  loop exits and nothing else touches *that handle's* buffer), processes
  asynchronously, then `uv-read-start!` to release and resume. A clean
  borrow/return protocol on machinery that already exists. **Only per-handle
  ownership can support it.**
- **Blast radius of a caller who violates the contract.** Per-handle: stale bytes
  from their own connection — contained. Per-loop: another connection's bytes —
  cross-connection data disclosure, on a platform with no CI lane to catch a
  regression. This asymmetry is a stronger argument for per-handle ownership
  than the zero-copy one.

## 8. GC and memory invariants (delta)

- No new `lock-object` traffic; the **thirteen** static trampolines
  (`native.sls:991-993`) remain the only locked objects (ADR-0008, as amended
  at v0.2/v0.3/v0.4).
- No new allocation class, so `live-counts`' frozen twelve-element literal
  (`tests/test-native.sps:1200-1204`) is unchanged.
- **`uv-stream-write-queue-size` alone is allocation-free.** The other five each
  allocate: the four buffer-size procedures take an `int` out-parameter, and
  `uv-tcp-peer-address` takes a `sockaddr_storage` plus an in-out length. The
  "validate before the first allocation" rule (`stream.sls` preamble) therefore
  binds all five, and each must free on every path out of a `guard` — the
  `tcp.sls:148-165` shape. §12.2's `'ENOTCONN` row exists so the memory lane has
  a failure path to walk; without it the leak is untestable.

## 9. What `chez-websocket` depends on

Recorded so v0.5 is validated against a real consumer. Separate project,
separate spec; nothing below is in v0.5's scope.

| Need | v0.5 surface | Status |
|---|---|---|
| Graceful close after the Close frame | `uv-shutdown!` | Exists. **Must not be `uv-close!`** — that flushes the queue with `UV_ECANCELED` (`unix/stream.c:454,464`) and the Close frame never reaches the wire. |
| Ping/pong keepalive, handshake deadline | `(libuv timer)` | Exists. Each timer is a handle with a close obligation on every abnormal path (ADR-0007). |
| Consumer backpressure | `uv-read-stop!` / `uv-read-start!` | Exists; §6 documents the pairing invariant and the close-race guard. |
| Write pacing | `uv-stream-write-queue-size` | **v0.5, D2.** |
| Write memory bound | consumer-side counting | Already possible; §4.1 says why the gauge is the wrong number for it. |
| Per-IP admission | `uv-tcp-peer-address` | **v0.5, D4.** The cap itself is server-layer policy. |
| Frame atomicity | two consecutive `uv-write!` calls | Structural: libuv drains head-of-queue FIFO and does not start the next request before the head completes. Recorded as a §10 measurement, **not** an assertion — see §12.4. |

## 10. Stage 0 spike (`spike/flow/`, findings in `spike/flow/FINDINGS.md`)

One question. Scripts continue the repo-wide sequence (`spike/flow/13-…`;
existing scripts run 00–12) and the directory carries a `.gitignore`.

**Q1 — Is 16384 the right default?**
Bytes per `read(2)` and syscall count per MiB at 4096 / 16384 / 65536, on
small-message and bulk profiles. D1's number is a judgement until this runs;
ADR-0019 records the measured answer.

**Prerequisite, stated because it will otherwise read as a libuv bug:** any
high-N leg needs `ulimit -n` raised — macOS's default soft limit is far below
what even 1,000 loopback pairs require, and the failure is `EMFILE`. FINDINGS
records achieved-vs-attempted N per platform. The committed `test-flow.sps`
fixtures cap N independently of the spike's, since every suite joins the
Valgrind lane at whatever N it uses.

**Linux mechanism** follows v0.4's: a temporary spike-branch workflow (`ci.yml`
fires only on push to `main`), run id recorded in FINDINGS, branch deleted after
harvest.

Per AGENTS.md, findings are measured, not reasoned, and each carries the command
that produced it.

## 11. Deferred, with reasons

### 11.1 Release-build allocation counters — own milestone

`src/libuv-shim.c:290-292` compiles every `chez_uv_live_*` to a constant `0`
outside a debug build, so a production process cannot observe foreign write
memory. That is a real defect. It is not this milestone, for three reasons:

- **As a rider it would not achieve its own goal.** The only Scheme accessor is
  `live-counts`, exported from `(libuv private native)`. Without a new public
  accessor and a facade row, a production operator still cannot read it without
  importing a private library — the exact thing the facade exists to prevent
  (`check-prod.sps:40-42` calls itself out as the one such caller).
- **It restructures `check-prod`.** That suite's pass condition is a single
  `(for-all (lambda (p) (zero? (cdr p))) during)` over every class
  (`check-prod.sps:77`). Making one counter real turns a correct release
  artifact into a FAIL. The fix is a two-gate predicate plus a row asserting the
  named list covers `(map car (live-counts))`, and both CI negative guards
  (`.github/workflows/ci.yml:258,357`, which assert `check-prod` FAILS against a
  relinked dev shim) must still fail.
- **It has an unpriced concurrency question.** `live_write_req` is a plain
  `long` with unsynchronized `+= 1` / `-= 1` (`libuv-shim.c:218,240-242`), and
  `libuv-shim.h:41-44` calls the counters "single-threaded test use only." Fine
  today, but promoting one to a production observable makes that an unstated
  dependency on a threadpool invariant documented elsewhere. Either state it or
  make it `_Atomic long` and price the portability.

Four sites also go stale and travel with it: `check-prod.sps:16-19`,
`Makefile:545-547`, `docs/building.md:80-93`, `src/libuv-shim.h:41-44`.

### 11.2 `orphan-events` cap — hygiene PR, no version bump

`handles.sls:682-688` is an uncapped `cons` + `reverse` with no clear. Real
motivation (a process running for months), no relationship to flow control, and
a cost this milestone should not absorb: seven rows across four suites index it
with `(list-tail (orphan-callback-events) before)`
(`test-loop.sps:223-225`, `test-tcp.sps:1414/1424` and `:1790/1818`,
`test-timer.sps:758/774` and `:868/870`, `test-dns.sps:130/1461`), and
`test-timer.sps:821` asserts a **zero delta** in `length` — which a saturated
log satisfies unconditionally, silently converting a meaningful assertion into
an empty one.

Two design points for that PR: it is a **bounded prefix log**, not a ring
(retain-first, drop-newest — a ring keeps the wrong end for a defect that fires
once and repeats), but it should retain first-N *and* last-M, since a defect
beginning after hours of uptime finds a full log and is otherwise represented
only by an anonymous increment. And the dropped count should be keyed per
orphan kind. It needs a monotonic total-recorded counter, the delta-style rows
re-pointed at the total rather than at `length`, and its own test using the
accessors directly, never `list-tail`.

## 12. Testing strategy

Harness rules restated as obligations: SRFI-64, every suite ends with its own
`(exit …)`, iteration caps never wall-clock, sentinels never `#f`/`0`, every new
assertion watched-to-fail against a mutation logged in
`.plans/flow-stage-N-mutation-log.md`.

### 12.1 The default-size pin — **must exist before D1**

**No test pins the default today.** Every `stream-read-buf-len` assertion is
against an explicit 4096 (`test-tcp.sps:1244`, `:1275`, `:1285`), a hand-set 64
(`:774`), or is self-comparing (`:1385`) — and `test-tcp.sps:1239-1240` says so
in a comment: *"the sizes here are this suite's own rather than the default."*

Stage 1 **adds** the pin against unchanged code: on a fresh connected handle,
start a read with the size **omitted** — the only path that reaches the default
— and assert `(stream-read-buf-len h)` equals 65536. Watch it fail by setting
the constant to 65535 in a scratch copy. Stage 2 then flips the constant and
this row together. A test that pins a constant is doing its job when it fails on
a constant change, and this one cannot do that job until it exists.

### 12.2 The congestion fixture (for D2)

A gauge test that only ever observes `0` passes against a stub, a misbound
handle pointer, and a `size_t` marshalling bug — and `0` is truthy in Scheme.
The assertion must observe a **positive** value and then observe it **fall**.

- **Determinism.** Shrink **both** `SO_SNDBUF` and the peer's `SO_RCVBUF` after
  connect/accept — shrinking only the writer's does not bound loopback
  buffering, since the peer's receive buffer absorbs independently and Linux
  doubles and floors the request (§4.2).
- **Sampling.** Write fixed-size chunks in an **iteration-capped** loop until the
  gauge reads positive, with `'gauge-never-went-positive` as the named
  exhaustion failure. Sample the positive value **synchronously after
  `uv-write!` returns and before any `uv-run`** (`stream.sls:100-104` submits
  inline); sample the fallen value only after `on-complete` fired.
- **Two mutations, one per assertion.** Constant `0` breaks the positive row; a
  constant non-zero (4096) breaks the fall row. Naming one mutation for two
  assertions leaves one of them unproven.
- **Per-stream discrimination.** A third idle stream on the same loop must read
  `0` at the instant the congested one reads positive, asserted as one
  `'(congested-positive idle-zero)` row. This is the only row that separates
  per-stream from per-loop or from a misbound pointer.
- **The gate.** `&uv-handle-closed` from a closed stream (§4.1).

Also here: the D3 setter rows. Assert `(< after before)` against the value read
*before* the set — `(<= n after)` is satisfied by a no-op setter that leaves the
large default in place. And a row calling the **getter twice** asserting no
change, so a getter that silently became a setter fails by name. That row is
what §4.2's whole split exists to justify.

### 12.3 Cross-stream isolation (new; the forward guard)

**No current test asserts that closing one stream leaves other streams on the
same loop still reading successfully.** Write it now, against the current
per-handle design where it passes, so Appendix A's conditions are guarded by a
test rather than by prose.

Shape: N readers on one loop; close one from inside its own callback. **Gate the
post-close writes** on `(eq? 'closed (uv-handle-state closed-one))` via a
`run-until`-style iteration-capped tick, and assert that gate as its own row —
`close-dispatch` frees on a *later* loop iteration than the `uv-close!` call
(`handles.sls:984-996`), so a write issued at close-*issue* time can complete
before the window under test opens, and a close that never completed must be a
named failure rather than a silently-early write.

Then assert every survivor completes a subsequent read with a **per-survivor
distinct** sentinel (`(seeded-bytes n i)`, seed space disjoint from the
pre-close payloads), plus a pairwise-distinctness row —
`test-echo.sps:163-172` records by name why one shared sentinel is not enough: a
cross-wired binding hands every survivor the same sentinel and every row goes
green. Compare with `compare-bytes`, whose failure value names the first
differing index. Assert the closed stream's own delivery count is unmoved.

**Mutation, in `src/` and not in the fixture:** make `alloc-dispatch` resolve
the most-recently-registered stream instead of the pointer libuv handed it
(`handles.sls:884`); survivors are then handed another handle's buffer and the
per-survivor payload rows fail by name. Deleting a survivor's `uv-read-start!`
proves only that the fixture is wired up — AGENTS.md requires the mutation break
the test *through the asserted property*.

**Honest scope limit:** of §7.3's two failure modes, the payload rows catch the
nulled-field/`UV_ENOBUFS` cascade on every platform. The
free-memory-fifteen-others-hold mode is a use-after-free that usually reads back
correct bytes and is caught only under `make test-memory` on the Linux leg
(ADR-0003).

### 12.4 What is deliberately not asserted

Head-of-queue drain makes two consecutive `uv-write!` calls non-interleaving
*structurally*, so "assert the byte stream is never interleaved" is an absence
assertion no mutation can break — an empty test by AGENTS.md's definition.
Recorded instead as a FINDINGS measurement with the vendor line that explains
it, and logged in the mutation log as an explicitly uncovered property with the
reason, per AGENTS.md.

The v0.5 assertion scoped to what the binding *does* own: accumulated bytes
equal payload-A then payload-B, **and** both `on-complete`s fired with
`'no-error` in submission order. That one fails if completions are routed by
kind instead of by block pointer.

### 12.5 The rest

- `uv-tcp-peer-address`: assert **both directions** — the client's peer port
  equals the server's listening port, and the accepted handle's peer port equals
  the client's `uv-tcp-getsockname-port`. The second direction is the only thing
  that catches an implementation returning the *local* address, and two
  independent ports shrink the byte-order blind spot (`tcp.sls:125-129` records
  why `read-net-u16` exists) from ~1/256 to ~1/65536. Row shape
  `(let-values (((a p) …)) (list a p))` against a list — a raise inside a bare
  `test-assert` becomes `#f`.
- `'ENOTCONN` on a bound-but-unconnected handle, via the guard-and-compare shape
  at `test-tcp.sps:1249-1254`.
- `test-native.sps`: `size_t` and int-out-param round-trips at stub level,
  independent of §12.2's fixture.
- Memory lane: `make test-memory` green. Per ADR-0003 the Linux Valgrind leg is
  the sole memory gate, and it is the only thing that catches §12.3's
  use-after-free mode and §8's five allocating procedures leaking on a failure
  path.

## 13. Milestone sequence

1. **Stage 0** — spike `spike/flow/`, Q1, `FINDINGS.md` with commands.
2. **Stage 1** — §12.1's default pin and §12.3's isolation regression, both
   against unchanged code, both watched to fail. Nothing in `src/` changes.
3. **Stage 2** — D1 constant, §6 docs, and the flip of Stage 1's default row.
   ADR-0019.
4. **Stage 3** — D2/D3/D4 bindings; §12.2, §12.4, §12.5.
5. **Stage 4** — D5: both comment sites, the `check-pins` tripwire and its help
   text. ADR-0018. ADR-0009's dated amendment. Appendix A into the repo.
6. **Stage 5** — D6 version bump, CHANGELOG (**Changed**, not Added, for D1),
   README ADR count 17 → 19 and status line, `docs/api.md` rows + reason symbols
   + Flow control section.
7. **Stage 6** — implementation plan written and adversarially reviewed *before*
   Stages 2–5 execute, per AGENTS.md: the plan's code blocks are executable spec
   and §5.1's four `foreign-procedure` forms have had no such pass. Then full
   `make test` + `make test-memory` + `make check-prod`, whole-branch review,
   squash merge, annotated tag `v0.5.0`, closing ritual.

Stage 1 precedes Stage 2 deliberately: both tests must exist and be
watched-to-fail before any behaviour changes underneath them.

## Appendix A — conditions on any future shared-buffer design

§7.3 rejects a shared per-loop read buffer. These are the conditions a future
attempt must satisfy, recorded here rather than in a review transcript because a
transcript is not in the working tree and will not be found by whoever opens
that milestone.

Three are now **guarded by tests** rather than merely written down — marked ✔.

1. **Resolve the size contract first.** Either remove `buffer-size` from
   `uv-read-start!` as a documented breaking change, or re-specify it as
   loop-scoped. Silently ignoring a caller's size is not permitted. ✔ guarded by
   §12.1's pin plus `test-tcp.sps:1241-1247`.
2. **If per-handle sizing survives**, the shared buffer is sized at the max ever
   requested on that loop and never shrinks, and growth may happen only outside
   a callback frame. A realloc reachable from a `uv-read-start!` issued inside
   `on-data` is exactly the hazard `stream.sls:186-193` exists to prevent.
3. **Move the free off the close path.** ✔ guarded by §12.3.
4. **Establish a loop-lifetime free site and write down why it is safe.** The
   argument — `uv_loop_close` requires all handles closed first — must be
   recorded, because it *replaces* the stated rule at `handles.sls:1003-1007`.
5. **Key the buffer on the loop record, never module-global.** `uv-run`'s
   re-entry guard is per-loop (`loop.sls:117`), so `on-data` under loop A may
   legally call `(uv-run loop-B 'nowait)`.
6. **`alloc-dispatch` stays infallible and allocation-free**, keeping the
   registry lookup as its gate. The unresolvable arm must still answer `(0,0)`
   so `unix/stream.c:1050-1053`'s bounded `UV_ENOBUFS`-and-return survives. ✔
   guarded by `test-tcp.sps`'s orphan-read row.
7. **Gate on an explicit handle-kind allowlist (`'tcp`, `'pipe`) that fails
   closed.** `uv_tty_t` genuinely retains the buffer across a threadpool
   boundary (`win/tty.c:616,631`), and `uv_udp_t` slices one `alloc_cb` across N
   datagrams (`unix/udp.c:256,277`).
8. **Make "copy-out completes before `on-data` is entered" a stated, tested
   invariant.** Today it is argument-evaluation order at `handles.sls:939`.
9. **Supersede or retire ADR-0009's zero-copy reservation**, weighing §7.4's
   retain-across-callbacks loss and the cross-connection blast radius.
10. **Name the shared buffer as a hard gate on the libuv pin** — D5's tripwire is
    the mechanism; a shared-buffer milestone must extend it.
11. **Re-specify the S10 counters** as per-loop, and treat the rewrite of
    `test-echo.sps:417-418` (16), `test-tcp.sps:1246-1247` (2) as the signal it
    is: a semantic change, not a transparent optimisation.
12. **Document the single-thread requirement.** The handle registry
    (`handles.sls:485`) is an unsynchronised `eqv-hashtable`; a shared buffer
    adds a second unsynchronised per-loop field to the same latent hazard.
