# Design Spec: chez-libuv v0.2 — DNS

- **Date:** 2026-08-21
- **Status:** Draft (2026-08-21) — pending Stage 0 DNS spike evidence
  (`spike/dns/FINDINGS.md`); see [decisions summary](#2-decisions-summary)
- **Supersedes:** nothing. Refines the
  [v0.1 design spec](2026-08-18-chez-libuv-v0.1-design.md) and
  `.plans/chez-http-server-architecture.md` §1 (the `dns.sls` box that
  diagram has carried since the start)
- **Scope:** v0.2 of the Chez Scheme binding for libuv: `(libuv dns)`

This document specifies the v0.2 delta over the shipped v0.1 binding (loop,
TCP, timers — tagged 2026-08-18). Everything the v0.1 spec says remains in
force except where a section below explicitly amends it. Each new decision is
backed by an ADR under `.plans/decisions/`; vendored-libuv facts are cited
against the pinned v1.52.1 submodule and become code-comment citations at
implementation time (§7).

---

## 1. Goal and non-goals

**Goal.** Bind libuv's complete DNS surface — `uv_getaddrinfo`,
`uv_getnameinfo` (async, threadpool-backed), and `uv_cancel` — as a new
R6RS library `(libuv dns)`, in the established house style: a thin legible
mirror of libuv's own verbs, records and Scheme values only at the public
boundary, no pointer ever visible outside `private/`. This is the binding's
first use of libuv's worker threads, and the first request kind that is owned
by a loop rather than by a handle; both firsts are governed by new ADRs and
gated on a Stage 0 spike (§10).

**Non-goals.**

- **No synchronous variants.** libuv itself offers the NULL-callback
  synchronous mode; this binding does not surface it. Async only.
- **No `tcp-connect-to-host` convenience.** Resolution composes with
  `uv-tcp-connect!` through the address vocabulary
  ([ADR-0012](decisions/0012-address-vocabulary.md)); a wrapper that hides
  the composition is the opinionated abstraction the v0.1 charter rejects.
- **No IPv6 scope-ID rendering.** `uv_ip_name` never reads
  `sin6_scope_id` (`vendor/libuv/src/uv-common.c:305-321`), so a link-local
  result renders as `"fe80::1"` with the zone silently dropped. v0.2
  **documents this limitation** (ADR-0012 + README) rather than papering
  over it; the recorded fix path is a later
  `OFFSETOF_SOCKADDR_IN6_SIN6_SCOPE_ID` shim entry plus
  `uv_if_indextoname`, at which point the address-string scratch size is
  re-derived (45 + 1 + IF_NAMESIZE).
- **No `AI_ADDRCONFIG`, `AI_V4MAPPED`, `AI_ALL`.** Their semantics vary by
  libc, and no offline-deterministic test can assert them — under the
  watched-to-fail rule they cannot be shipped honestly yet. Adding one later
  is one shim table entry plus one symbol in a validation set.
- **No process, filesystem, or UDP bindings.** v0.2 adds exactly DNS.
- **No resolver features beyond libuv's.** No c-ares, no record types
  (MX/TXT/SRV), no caching, no `/etc/hosts` policy. What `getaddrinfo(3)`
  and `getnameinfo(3)` do on the host is what this binding does.

---

## 2. Decisions summary

The three new ADRs carry
`Status: Proposed (2026-08-21) — pending Stage 0 DNS spike evidence
(spike/dns/FINDINGS.md)` and flip to Accepted at spike exit, exactly as
v0.1's ten did. ADR-0008 is amended **in place** (the dated-amendment style
its 2026-08-18 correction block established), not superseded.

| ADR | Decision |
|---|---|
| [0011](decisions/0011-handle-less-loop-scoped-requests.md) | DNS requests are handle-less and loop-scoped: `uv-req-record` reused with `handle = #f`, loop resolved via the registry entry; teardown is cancel-then-drain; a pending request makes `uv-loop-close!` fail `'EBUSY` |
| [0012](decisions/0012-address-vocabulary.md) | An address is a presentation-form string, a port a separate exact integer; both directions go through libuv's own parse/format code; scope IDs are dropped in v0.2, with the shim-offset fix path recorded |
| [0013](decisions/0013-offline-deterministic-dns-tests.md) | Gating suites use numeric-only lookups; `localhost`, named services, and external network are banned; `AI_ADDRCONFIG` is never set (extends ADR-0010 to the resolver) |
| [0008](decisions/0008-static-trampolines-and-handle-registry.md) *(amended)* | Eight trampolines become **ten**; the invariant is restated as "one locked trampoline per callback *type*, constant per process", which the literal eight was an instance of |

One further v0.2 decision is recorded **without** an ADR, because it closes
an already-flagged v0.1 obligation rather than opening a new axis: the
comment at `src/libuv/loop.sls:166-177` records that a direct
`uv-loop-close!` discards a stored pending callback error. In v0.2,
`uv-loop-close!` completes the close and then **re-raises** that stored
error, composed as `&uv-callback-error`, exactly as `uv-run`'s exit path
does (§6). The decision lives in the rewritten loop.sls comment and the
CHANGELOG entry, guarded by one test.

---

## 3. Module layout (delta)

```
src/
  libuv.sls                     # facade: + DNS re-export block (§4.6)
  libuv/
    dns.sls                     # NEW  (libuv dns): public API + both dispatchers
    private/
      addrinfo.sls              # NEW  (libuv private addrinfo): pure record +
                                #      symbolic-hints validation; imports (rnrs)
                                #      only (conditions.sls pattern), so it is
                                #      check-purity-coverable
tests/
  test-dns.sps                  # NEW  driven suite; wildcard-picked-up
  test-addrinfo.sps             # NEW  pure suite; added to PURE_TESTS
                                #      (a deliberate explicit Makefile edit —
                                #      that list is not a wildcard)
spike/
  dns/                          # NEW  Stage 0 scripts + FINDINGS.md (§10)
```

Modified: `src/libuv/private/native.sls`, `src/libuv/private/handles.sls`,
`src/libuv-shim.c`/`.h`, `src/libuv/private/constants.sls`,
`src/libuv/loop.sls`, `src/libuv/tcp.sls` (helper lifts out, §5.6),
`tests/test-facade.sps`, `tests/test-loop.sps:193-195`,
`tests/test-native.sps:1124-1126` (the two hard-coded eight-name literals),
`Makefile` (`PURE_TESTS` only), `README.org`, `CHANGELOG.md`,
`Akku.manifest` (0.2.0 — `check-pins` does **not** cover it; manual bump).

The v0.1 rule stands: `private/` holds every module that touches a pointer.
`dns.sls` itself handles pointers only inside its two dispatchers, which is
the same posture `handles.sls` established; its public procedures traffic in
records, strings, symbols, and exact integers exclusively.

---

## 4. Public API

### 4.1 `uv-getaddrinfo!`

```scheme
(uv-getaddrinfo! loop node service on-complete)          ; hints omitted
(uv-getaddrinfo! loop node service hints on-complete)
  => opaque dns request
```

Validation — all of it before the first allocation, each failure an
`&uv-invalid-argument` with `who 'uv-getaddrinfo!` and a specific reason
symbol:

- `loop` open (`require-open-loop`; closed loop is `&uv-handle-closed`
  kind `'loop`).
- `node` and `service` each a string or `#f`; **not both absent** —
  refused in Scheme rather than letting libuv answer `UV_EINVAL`, because
  it is a caller bug, not a lifecycle outcome.
- Strings containing `#\nul` are **refused**. Chez's `string` marshalling
  NUL-terminates, so `"evil\x0;.example"` would silently resolve its prefix
  — plausible and wrong. The refusal is a validation clause, not a comment.
- `hints` well-formed per §4.2; `on-complete` a procedure.

`node`/`service` cross as Chez `string` FFI arguments. This is lifetime-safe
because `uv_getaddrinfo` memcpys node, service, and hints into one req-owned
block before returning and frees that block itself
(`vendor/libuv/src/unix/getaddrinfo.c:174-208, 114-126`) — the same
argument native.sls:339-345 records for `uv_ip4_addr`. (Chez-side `#f`→NULL
and UTF-8 transcoding are spike-confirmed, Q1.)

Returns the opaque request record — a value only success produces. On a
synchronous failure nothing is left half-registered (§5.5).

### 4.2 Hints

An association list with symbol keys — R6RS has no keywords, positional
optionals cannot carry four independently-optional fields, and an alist is a
legible mirror of `struct addrinfo`'s named fields:

```scheme
'((family . inet6) (socktype . stream) (protocol . tcp)
  (flags . (canonname numeric-host)))
```

Validation (all `&uv-invalid-argument`, before allocation): a list of pairs;
keys drawn from `{family socktype protocol flags}`; duplicate keys refused
(`'duplicate-hint-key`); unknown keys refused (`'unknown-hint-key`);
`family ∈ {unspec inet inet6}`; `socktype ∈ {stream dgram}`;
`protocol ∈ {tcp udp}`; `flags ⊆ {passive canonname numeric-host
numeric-serv}`. **Closed sets, no raw ints accepted** — v0.2 binds what it
tests. Every symbol maps through a shim-snapshotted constant
([ADR-0005](decisions/0005-constants-are-never-transcribed.md)); an omitted
key leaves its struct field zero.

**Omitted, `#f`, and `'()` all canonicalize to a NULL hints pointer** — the
platform's own documented default. Two reasons: synthesizing
`ai_socktype = SOCK_STREAM` (Node's choice) is result-shaping policy this
binding's charter refuses; and glibc documents NULL hints as implying
`AI_V4MAPPED|AI_ADDRCONFIG` while a zeroed struct disables that, so "omitted"
and "empty" would otherwise be two silently different behaviors on Linux.
The documented consequence (README): NULL hints yields one entry per
(address × socktype) — commonly `stream`, `dgram`, and on Linux `raw` — and
`'((socktype . stream))` is the one-liner for callers who want one entry per
address.

`service` accepts strings (or `#f`) only, never exact integers: the
parameter is genuinely a name domain (`"http"` or `"80"`), and
auto-`number->string` is a convenience the mirror rule does not owe. The
asymmetry with the record's integer `port` output is real — the output is a
decoded sockaddr field, the input is resolver text.

### 4.3 The `uv-addrinfo` record

Defined in `(libuv private addrinfo)` — pure data, `(rnrs)` only, all
fields immutable. **`make-uv-addrinfo` is public**: the `%`-private
constructor rule exists for records backed by native memory ("a record whose
ptr did not come from a successful `uv_*_init` is a segfault waiting to
happen"); this record holds no pointer, and a caller's test double is
legitimate — the same reasoning under which the facade exports the condition
constructors (libuv.sls:58-64).

| field | accessor | type |
|---|---|---|
| family | `uv-addrinfo-family` | `'inet` \| `'inet6` |
| socktype | `uv-addrinfo-socktype` | `'stream` \| `'dgram` \| `'raw` \| exact int |
| protocol | `uv-addrinfo-protocol` | `'tcp` \| `'udp` \| exact int (0 = unspecified) |
| address | `uv-addrinfo-address` | presentation string via `uv_ip_name` (scope IDs dropped — §1, ADR-0012) |
| port | `uv-addrinfo-port` | exact int 0..65535 |
| canonname | `uv-addrinfo-canonname` | string \| `#f` (first entry, under `canonname` flag, only) |

Two policies the table encodes:

- **Non-INET-family entries are skipped during the chain walk.** The record
  has no honest representation for them — `uv_ip_name` answers
  `UV_EAFNOSUPPORT` for anything but INET/INET6
  (`vendor/libuv/src/uv-common.c:318-320`) — and skipping cannot fabricate
  data. Corollary, documented: `err = #f, results = '()` is a possible
  outcome (a success whose entries were all skipped, indistinguishable from
  an empty success). A synthetic-chain test pins the skip policy (§9).
- **Unmapped socktype/protocol values pass through as the raw exact int** —
  lossless, and trivially discriminable with `symbol?`. The justification is
  that the raw int IS the diagnostic payload here; this is deliberately
  *not* cited to ADR-0006, whose shape (sentinel symbol + separate raw-code
  field) is a different contract. `'raw` is in the known socktype set
  because Linux NULL-hints chains genuinely contain `SOCK_RAW` entries.

### 4.4 Callback contracts

Both callbacks run under `dispatch-guarded` against the request's loop,
errors as condition **objects** never raised across the boundary, `#f` =
success — the `status->err` convention unchanged.

**`uv-getaddrinfo!`'s `(on-complete err results)`:**

- Success: `err = #f`; `results` a fresh list of `uv-addrinfo` records in
  resolver order (order is meaningful — RFC 6724 destination selection).
- Error: `err` an `&uv-errno-error` with errno `'EAI_NONAME`,
  `'EAI_AGAIN`, …; `results = '()` — never `#f` (`err` is the sole
  discriminant; `'()` lets `for-each` run unconditionally, and `#f` is the
  named worst sentinel).
- Cancelled: identical to error with errno `'EAI_CANCELED` — one spelling,
  because libuv itself rewrites `UV_ECANCELED` before the callback
  (`vendor/libuv/src/unix/getaddrinfo.c:128-133`). No third arm.
- Lifetime: the chain is walked and copied, `uv_freeaddrinfo` is called,
  and the request block is deregistered/freed/counted/ptr-zeroed — all
  **before** `on-complete` runs. Nothing the callback stores points into
  foreign memory (ADR-0009), and `(uv-cancel! req)` from inside `req`'s own
  `on-complete` deterministically answers `#f`.
- The callback fires exactly once in every outcome, **with one documented
  caveat**: if the chain conversion itself raises (a dispatcher bug, not
  user code), the block is freed through the same path *without* delivery
  and the failure surfaces via `loop-record-error!` — the binding never
  invokes `on-complete` with fabricated data (§5.4).

**`uv-getnameinfo!`'s `(on-complete err host service)`:**

- Success: `err = #f`, `host` and `service` both strings.
- Error/cancelled: `err` a condition (`'EAI_NONAME` under `name-required`,
  `'EAI_CANCELED`, …), `host = #f`, `service = #f` — mechanical, because
  libuv passes NULL for both on every failure and `c-string->string` maps
  NULL to `#f` (native.sls:454-466).

### 4.5 `uv-getnameinfo!`, `uv-cancel!`, `uv-dns-request?`

```scheme
(uv-getnameinfo! loop ip port on-complete)           ; flags omitted => '()
(uv-getnameinfo! loop ip port flags on-complete)
  => opaque dns request
```

`ip`/`port` use the TCP input vocabulary exactly (`require-address`,
`require-port` — ADR-0012 applied on the way in); `flags` a list drawn from
the closed set `{numeric-host numeric-serv name-required dgram}` (reason
`'unknown-nameinfo-flag`).

```scheme
(uv-cancel! req) => #t | #f
```

- **`#t`** — the native cancel won (rc 0: the work was still queued);
  the callback WILL still fire, with `'EAI_CANCELED`, through the normal
  freeing site. `#t` is a value only success produces.
- **`#f`** — too late, uniformly: the work is running or completed
  (rc `UV_EBUSY`), or the request is already freed (its stored ptr is
  zeroed at the freeing site) — in the freed case **no native call is
  made**, since passing the stale pointer to `uv_cancel` would fault on the
  `req->type` read (`vendor/libuv/src/threadpool.c:399-441`). Either way
  the callback delivers (or delivered) the real result.
- Boolean, not raise: loop-close's `'EBUSY` names a state the caller must
  fix; cancel's `EBUSY` is the unavoidable outcome of a race the caller
  cannot influence — information, not an error. Tests never assert the
  boolean alone; they assert the paired consequence per branch.
- Domain: **dns requests only** — anything else raises
  `&uv-invalid-argument` reason `'not-a-cancellable-request` (libuv would
  answer `UV_EINVAL` for the v0.1 request kinds; refusing in Scheme names
  the actual mistake as static, not racy). A future `uv_work`/`uv_fs`
  binding widens the domain without a rename — tcp.sls:16-18 reserved
  exactly this shape.
- Double-cancel before the callback fires answers `#t` twice — harmless
  (libuv unlinks and re-inserts the same node, rc 0 again), documented, not
  defended.

**`uv-dns-request?`** — public predicate, a thin kind check over the reused
request record (§5.3). It exists to document `uv-cancel!`'s domain; the
request record exposes nothing else, matching v0.1's opaque requests.

### 4.6 Facade and conditions

`src/libuv.sls` re-exports, by name (the by-name-only discipline holds):
`uv-getaddrinfo!` `uv-getnameinfo!` `uv-cancel!` `uv-dns-request?`
`make-uv-addrinfo` `uv-addrinfo?` plus the six accessors.
`tests/test-facade.sps` gains the expand-time rows and one driven numeric
lookup through the facade.

**No new condition types.** All 14 `EAI_*` codes are already in
`UV_ERRNO_MAP` (`vendor/libuv/include/uv.h:81-94`), flow through the shim's
X-macro, and answer from `errno-value->symbol` today — zero errno work.
Caller bugs are `&uv-invalid-argument` with new reason symbols (reasons are
data, not types); cancellation is `'EAI_CANCELED` on the ordinary
`&uv-errno-error`, never an invented `&uv-cancelled` (one errno, one
spelling).

---

## 5. Internals

### 5.1 native.sls additions

Raw bindings (native.sls stays the only FFI file):

```scheme
uv_getaddrinfo   (uptr uptr uptr string string uptr) -> int
uv_getnameinfo   (uptr uptr uptr uptr int)           -> int
uv_cancel        (uptr)                              -> int
uv_freeaddrinfo  (uptr)                              -> void
uv_ip_name       (uptr u8* size_t)                   -> int
```

`uv_ip_name` is not exported raw; it is wrapped as
`(sockaddr->address-string addr-ptr)` → string | `#f`, following the
`uv_strerror_r` caller-buffer pattern: a **fresh 64-byte scratch per call**
(INET6_ADDRSTRLEN is 46; scratch sizes are not protocol constants) for
callback re-entrancy, `#f` on nonzero rc, and — deliberately — **`#f` for a
zero pointer without calling native**. `uv_ip_name` dereferences
`sa_family` unconditionally (`vendor/libuv/src/uv-common.c:311`); the
zero-check is what makes synthetic-chain tests safe to build with NULL
`ai_addr` and makes the offset-swap mutation fail *by name* instead of by
SIGSEGV (§9).

One new memory helper: `c-uptr-ref` beside `c-int-ref`, same validation —
the chain walk must read `ai_next`/`ai_addr`/`ai_canonname` pointer fields
and only native.sls may call `foreign-ref`.

**Two new locked trampolines** — neither existing arity matches the DNS
callback typedefs (`vendor/libuv/include/uv.h:345-352`):
getaddrinfo `(uptr int uptr) -> void`, getnameinfo
`(uptr int uptr uptr) -> void`. `dispatcher-names` widens to **ten**:
`'(alloc read connection write-done close timer shutdown connect
getaddrinfo getnameinfo)`. `install-callback-dispatchers!`'s validation
measures `(length dispatcher-names)`, handles.sls seeds stubs and installs
by mapping the same list (handles.sls:977-982, 1005-1007), and
test-native's uninstalled-stub loop iterates it — all three widen
automatically (verified). Wrappers `uv-getaddrinfo-native` /
`uv-getnameinfo-native` bake the entry points in; nothing outside
native.sls holds a C address.

Helper lifts **into** native.sls, exported: `fill-sockaddr!` (tcp.sls:84-87)
and `align-16` (tcp.sls:457) — boundary-writing mechanics and
allocation-layout arithmetic respectively, neither carrying dispatch
policy, so native.sls's mechanical/policy-free review property survives.
tcp.sls imports them and deletes its private copies.

### 5.2 Shim and constants additions

The constants-only rule (ADR-0002) holds; shim.c gains `#include <netdb.h>`.
New table entries, all computed, never transcribed (ADR-0005), each with a
constants.sls accessor and a test-native presence row:

- Req-type tags: `UV_GETADDRINFO`, `UV_GETNAMEINFO`.
- Sizes: `SIZEOF_UV_GETADDRINFO_T`, `SIZEOF_UV_GETNAMEINFO_T` (both
  cross-checked against runtime `uv_req_size` like the existing pairs),
  `SIZEOF_ADDRINFO`.
- **The portability trap's antidote** — `struct addrinfo` offsets:
  `OFFSETOF_ADDRINFO_{AI_FLAGS,AI_FAMILY,AI_SOCKTYPE,AI_PROTOCOL,AI_ADDRLEN,AI_ADDR,AI_CANONNAME,AI_NEXT}`.
  glibc orders `ai_addr` before `ai_canonname`; Darwin reverses them
  (verified in both headers). Any ftype guess is wrong on one platform;
  offsets MUST come from the shim. The Darwin/Linux divergence is *why*
  the presence rows exist.
- `SIZEOF_SOCKADDR_IN6`, `OFFSETOF_SOCKADDR_IN6_SIN6_PORT` — the v0.1
  getsockname-port shortcut of reading `sin_port`'s IPv4 offset for both
  families (argued-not-checked, tcp.sls:138-144) is not repeated: the chain
  names each entry's family, so the honest per-family offset is one lookup
  away.
- Enum values: `AF_INET6`; `SOCK_STREAM SOCK_DGRAM SOCK_RAW`;
  `IPPROTO_TCP IPPROTO_UDP`; `AI_PASSIVE AI_CANONNAME AI_NUMERICHOST
  AI_NUMERICSERV`; `NI_NUMERICHOST NI_NUMERICSERV NI_NAMEREQD NI_DGRAM`.
  **No `AI_ADDRCONFIG`** — under the closed validation sets it would be
  unreachable dead weight (§1 non-goal). `SOCK_RAW` is included because
  `'raw` is in the decode vocabulary (§4.3).

**Two new counter classes** `getaddrinfo-req` / `getnameinfo-req` — the
write-req/connect-req per-kind precedent, chosen over one merged `dns-req`
class for sharper leak attribution between the two block shapes. Five touch
points each: shim.h prototypes, shim.c dev arm, shim.c no-op arm,
native.sls bindings, the `live-counts` alist. Bumped `new!` after
registration, `free!` at the freeing site; loop-thread-only (completions
run only on the loop thread — §7). `check-prod` iterates whatever
`live-counts` returns, so both classes are covered without an edit.

### 5.3 handles.sls: handle-less loop-scoped requests (ADR-0011)

**Reuse `uv-req-record` with `handle = #f`.** No new record type — a
parallel type would forfeit the "a request block is freed in exactly one
place" property by creating a second freeing site, for no gain the
`#f`-handle amendment doesn't also deliver. Record kinds `'getaddrinfo` /
`'getnameinfo`; registry kinds `'getaddrinfo-req` / `'getnameinfo-req`,
registered **with the loop passed explicitly** (`registry-register!`
already takes it). `handle-kinds` is untouched, so
`registry-snapshot-for-loop` keeps request entries out of the teardown
close-sweep automatically; being in the registry is what keeps the req
record and its `on-complete` closure alive across threadpool flight — the
registry-as-GC-root role, unchanged (§8).

**`complete-request!` generalizes** in two ways:

1. The loop read `(handle-loop (req-handle req))` at handles.sls:599 —
   the **sole** `req-handle` reader in the tree — becomes
   `(registry-loop-of block-ptr)`, read **before** the deregister. The
   entry provably exists at that point (the `registry-ref` just succeeded
   on the same key), and for TCP kinds the entry's loop *is* the handle's
   loop by construction, so the substitution is behavior-preserving — one
   code path for all five request kinds, with the TCP suites guarding the
   equivalence.
2. Delivery becomes `(apply on-complete err extras)`. Existing call sites
   pass no extras; getaddrinfo passes the converted results list,
   getnameinfo the two copied strings. Extras are always already-copied
   Scheme values, computed before anything is freed.

`complete-request!` is exported; `abandon-request!` (tcp.sls:445-449) is
lifted here beside it, exported — it is registry+record+`free!` vocabulary
and dns.sls needs the identical sync-failure undo.

New export `(cancel-requests-for-loop! loop)`: **snapshot-first** walk (the
same R6RS mutate-while-iterating rationale as
`registry-snapshot-for-loop`) of this loop's dns request entries,
best-effort `uv_cancel` on each live pointer, **return codes ignored** —
queued work completes immediately with `'EAI_CANCELED`, running work is
uncancellable and the drain waits it out (§6). The public `uv-cancel!`
policy stays in dns.sls; both are thin callers of the one raw binding, and
loop.sls never imports `(libuv dns)`.

Comment amendments, each a claim v0.2 falsifies: handles.sls:308-312 (the
`handle` field as "the only route back to the owning loop"),
handles.sls:433-439 (teardown-sweep rationale, now scoped to handle-owned
requests), and the header's "no stubs left" note (dns dispatchers are
seam-installed; the stub is legitimately reachable again in a process that
never imports `(libuv dns)`).

### 5.4 The dispatchers (in dns.sls)

Both are installed at `(libuv dns)`'s library-body time via
`install-dispatch-procedure!` — precisely the late-added-callback-type case
the handles.sls:885-892 comment anticipates. A process that never imports
the library keeps the contained raising stub, and nothing can start a DNS
request without the import.

**Both dispatchers check the req record's KIND, not merely `uv-req?`.** A
DNS req record of the wrong kind IS a `uv-req?`, and the two DNS arities
differ from each other — cross-pairing is UB, not a clean failure: a
3-argument C call into the 4-argument callable reads a garbage register,
and walking `req->host` (a char array *inside* the co-allocated block,
`vendor/libuv/include/uv/unix.h:353-354`) as an addrinfo chain ends in
`freeaddrinfo(3)` on an interior pointer of a `foreign-alloc` block — heap
corruption. A kind mismatch routes to the contained-error arm with **no
`uv_freeaddrinfo`** (the pointer's provenance is unknown in that bug state;
the leak is accepted).

getaddrinfo dispatch order — each step's position is load-bearing:

1. Registry lookup. No entry (orphan): `uv_freeaddrinfo` the chain (its
   provenance is then presumably genuine), record the orphan. Entry of the
   wrong kind: contained-error arm, no free (above).
2. Capture the loop via `registry-loop-of` **first** — the
   conversion-failure arm needs it after the entry is gone.
3. Convert the chain while it is alive, under a capture-guard:
   `addrinfo-chain->list`, exported for synthetic-chain tests.
4. `uv_freeaddrinfo` — **exactly once, unconditionally, before any user
   code runs.** `res` is NULL on every failure/cancel status (initialized
   NULL at submit, written only by a successful `getaddrinfo(3)`), and
   `uv_freeaddrinfo(NULL)` is a no-op — so the unconditional call is
   correct on every path.
5. No conversion failure → `complete-request!` with the results extras:
   deregister → free block → count → zero ptr → **then** `on-complete`
   under `dispatch-guarded`.
6. Conversion failure (a dispatcher bug) → free the block through the same
   sequence **without delivery**, then `loop-record-error!` — never invoke
   the callback with fabricated data. This is the documented caveat on
   "exactly once" (§4.4).

Chain walk (`addrinfo-chain->list`): `ai_next` via `c-uptr-ref` at the shim
offset; `ai_family`/`ai_socktype`/`ai_protocol` via `c-int-ref` + snapshot
comparison; skip non-INET families (§4.3); address via
`sockaddr->address-string`; port via `read-net-u16` at the **per-family**
offset (`sin_port` vs `sin6_port` — no shared-offset shortcut); canonname
via `c-string->string`.

getnameinfo dispatch: **copy both strings first** — they point INTO the
request block itself — then `complete-request!` with `(hostname service)`
extras. NULL→`#f` falls out of `c-string->string`.

### 5.5 Start-call flow and co-allocation

Both start procedures mirror tcp.sls:231-251 exactly: validate everything →
`alloc-zeroed` one block → fill the co-allocated area → make record →
`registry-register!` → `count-*-new!` → native call under a guard whose
failure arm runs `abandon-request!` + counter + re-raise.

- getaddrinfo: `[uv_getaddrinfo_t | pad16 | struct addrinfo hints]`; hints
  fields written with `c-int-set!` at shim offsets into the zeroed tail;
  the native call receives 0 (NULL) as the hints pointer when the caller
  supplied none (§4.2). Hints only *need* to survive the sync call (libuv
  memcpys them), but co-allocation settles the lifetime by construction —
  the connect-sockaddr rule verbatim.
- getnameinfo: `[uv_getnameinfo_t | pad16 | sockaddr_storage]`, filled by
  the lifted `fill-sockaddr!`; libuv copies it into `req->storage` before
  returning, and it dies in the block's single free.

Post-registration sync failures exist **only for getaddrinfo**: empty
hostname → deterministic `UV_EINVAL` from `uv__idna_toascii`
(`vendor/libuv/src/idna.c:325-326`), overlong hostname → `UV_E2BIG`
(idna.c:244) — both after our register/count, before any possible callback
(`getaddrinfo.c:163-171` runs before `uv__work_submit`), so the abandon
guard never races a completion. Consequently the binding adds **no
Scheme-side empty-string validation** — doing so would make the guard
untestable (§9). getnameinfo has no reachable post-registration sync
failure (every `EINVAL` path precedes `uv__req_init`; with a callback it
then returns 0 unconditionally): its abandon guard is
unreachable-by-construction and is recorded as such, per the house
convention for unreachable arms (tcp.sls:150-156 precedent).

### 5.6 tcp.sls

Loses its private `fill-sockaddr!`, `align-16`, `abandon-request!` (§5.1,
§5.3) and imports the lifted names. No behavior change; the TCP suites
guard it.

---

## 6. Teardown and close semantics

**`uv-loop-teardown!` becomes cancel-then-drain.** Before the existing
close sweep, `(cancel-requests-for-loop! loop)` best-effort-cancels every
dns request of this loop. Contract: **every in-flight dns request's
`on-complete` runs before teardown returns** — with `'EAI_CANCELED` if the
cancel won, with the real result if the work was already running. The drain
then works because an active req keeps `uv__loop_alive` true
(`vendor/libuv/src/unix/core.c:393-397`), so `uv-run 'default` **blocks**
(does not spin the 1024-iteration cap) until the worker posts `wq_async`
— one blocking iteration per in-flight request, delivered under the normal
guard, a raising `on-complete` caught as `&uv-callback-error` like any
`on-close` raise.

Documented residuals, stated honestly:

- A running `getaddrinfo(3)` is uninterruptible; the drain's blocking
  iteration is then **wall-clock-unbounded** (up to the OS resolver's own
  timeout). The iteration cap is unaffected — it bounds iterations, not one
  iteration's duration. The alternative (abandoning a block a worker may
  still write into) is a use-after-free by design.
- **The cancel sweep runs once.** An `on-complete` (delivered
  `'EAI_CANCELED` during the drain) that submits a *new* dns request gets
  that request drained, not cancelled — the same once-only shape as the
  v0.1 close sweep.

**`uv-loop-close!` needs no DNS change**: a pending request makes
`uv_loop_close` answer `UV_EBUSY` (`vendor/libuv/src/uv-common.c:885`),
which surfaces exactly as open handles do today — `&uv-errno-error 'EBUSY`,
loop untouched and usable. One new test asserts it.

**New in v0.2 (the recorded no-ADR decision, §2):** after a *successful*
close, `uv-loop-close!` re-raises a stored pending callback error, composed
as `&uv-callback-error`, mirroring `uv-run`'s exit path — closing the v0.1
obligation flagged at loop.sls:166-177. The comment is rewritten to record
the decision; one TDD'd test covers the re-raise.

---

## 7. Verified vendor facts (pinned libuv v1.52.1)

Each row was verified against the vendored source during design (design
panel + two adversarial reviews); at implementation time these citations
move into code comments beside the line that depends on them.

| Fact | Evidence |
|---|---|
| `uv_getaddrinfo` memcpys node/service/hints into one req-owned block before returning and frees it itself → Chez `string` marshalling is lifetime-safe | `vendor/libuv/src/unix/getaddrinfo.c:174-208` (copy), `:114-126` (free) |
| `uv_getnameinfo` memcpys the sockaddr into `req->storage`; the callback's hostname/service point INTO the req block, NULL on every failure → copy-before-free mandatory; NULL→`#f` fits | `vendor/libuv/src/unix/getnameinfo.c:89-99`; `vendor/libuv/include/uv/unix.h:353-354` |
| `uv_cancel`: 0 only while queued (callback still fires; `UV_ECANCELED` rewritten to `UV_EAI_CANCELED` for both DNS kinds); running/completed → `UV_EBUSY`; non-threadpool kinds → `UV_EINVAL`; exactly one callback in every outcome; double-cancel-before-fire re-returns 0 harmlessly | `vendor/libuv/src/threadpool.c:399-441`; `vendor/libuv/src/unix/getaddrinfo.c:128-133` |
| All 14 `EAI_*` codes are in `UV_ERRNO_MAP` → `errno-value->symbol` answers `'EAI_NONAME`/`'EAI_CANCELED` today; zero errno work | `vendor/libuv/include/uv.h:81-94` |
| Active reqs keep the loop alive and make `uv_loop_close` answer `EBUSY`; the teardown drain blocks (not spins) until `wq_async` posts | `vendor/libuv/src/unix/core.c:393-397`; `vendor/libuv/src/uv-common.c:885` |
| `uv_ip_name` exists (1.43 < declared floor 1.44.0) and does NOT render IPv6 scope IDs | `vendor/libuv/src/uv-common.c:305-321`; floor: `Makefile:57-59`, `README.org:45` |
| `struct addrinfo` field order differs between glibc (`ai_addr` before `ai_canonname`) and Darwin (reverse) → offsets MUST come from the shim | glibc netdb.h vs macOS SDK netdb.h:147-155 (both verified); ADR-0005 mechanism |
| `UV_THREADPOOL_SIZE` read once at first `uv__work_submit`; workers run pure libc (never Scheme); completions run on the loop thread; workers are never joined → still-reachable at exit, outside the definite-only valgrind gate | `vendor/libuv/src/threadpool.c:194-217` (init), `:319-342` (loop-thread done), `vendor/libuv/src/unix/getaddrinfo.c:96-103` (pure libc worker) |
| Post-registration sync failures: getaddrinfo only (empty/overlong hostname → `UV_EINVAL`/`UV_E2BIG` from idna, after register, before submit); getnameinfo has none — its abandon guard is unreachable-by-construction | `vendor/libuv/src/idna.c:325-326, :244`; `vendor/libuv/src/unix/getaddrinfo.c:163-171` |
| `res` is NULL on every getaddrinfo failure/cancel; `uv_freeaddrinfo(NULL)` is a no-op → the dispatcher's unconditional free is correct on every path | `vendor/libuv/src/unix/getaddrinfo.c:188, :225-228` |
| DNS callback typedefs `(req*, int, addrinfo*)` / `(req*, int, const char*, const char*)` match no existing trampoline arity | `vendor/libuv/include/uv.h:345-352` |

---

## 8. GC and memory invariants (delta over v0.1 §10)

- **Locked objects are exactly the ten static trampolines** — ADR-0008
  amended; the invariant was always "one per callback type, constant per
  process", and ten is the new instance of it. Still one file, still locked
  once, never per request.
- **The registry remains the GC root, unchanged in mechanism.** A dns
  request entry (registered with the loop explicitly, since there is no
  handle to inherit one from) keeps the req record and the caller's
  `on-complete` closure reachable for the whole threadpool flight — no
  guardian, no per-request lock, no Scheme object visible to a worker
  thread.
- **The single-freeing-site property is preserved by construction**: the
  reused `uv-req-record` means dns blocks are freed where every request
  block is freed — `complete-request!` on the async path,
  `abandon-request!` as the sync-failure undo — both zeroing the stored
  `uptr` at the freeing site. A new record type would have created a second
  site; that alternative was rejected (§5.3).
- **The addrinfo chain is libuv-owned** and freed exactly once, by
  `uv_freeaddrinfo` in the getaddrinfo dispatcher, before user code (§5.4).
  Synthetic test chains are built with `alloc-zeroed` and freed with
  `free!` — **never** `uv_freeaddrinfo`, which is legal only on
  getaddrinfo-owned chains.
- **Two new counter classes** (`getaddrinfo-req`, `getnameinfo-req`) join
  the six v0.1 classes; asserted nonzero mid-test then balanced, per the
  sentinel rule. Bumps stay loop-thread-only — the shim counters'
  single-threaded caveat holds because completions run only on the loop
  thread (§7).
- **Threadpool workers are never joined**: worker stacks and pthread TLS
  are still-reachable at exit — outside `--errors-for-leak-kinds=definite`,
  the expectation recorded in the Makefile's test-memory comment so a
  future reader does not "fix" it (Q2 supplies the evidence).

---

## 9. Testing strategy (delta)

**Policy (ADR-0013, extending ADR-0010).** The resolver's *configuration*
(`/etc/hosts`, nsswitch, mDNSResponder, `/etc/services`) is not part of
this project's oracle. Gating suites use numeric-only lookups:
`AI_NUMERICHOST` forward lookups of `"127.0.0.1"`/`"::1"` (pure formatting,
zero network); `AI_NUMERICHOST` + a non-numeric name → deterministic
`'EAI_NONAME`; `NI_NUMERICHOST|NI_NUMERICSERV` reverse of numeric
endpoints. `"localhost"`, named services, and external-network lookups are
banned; `AI_ADDRCONFIG` is never set (it makes `::1` results
container-configuration-dependent). The accepted cost: no non-numeric
*success* path is exercised — everything this binding owns (submission,
threadpool round-trip, chain copy-out, freeing, dispatch) is fully
exercised by the numeric cases, including multi-entry chains.

**`tests/test-dns.sps`** — wildcard-picked-up by `TESTS`/`MEMORY_TESTS`.
Prologue: `putenv UV_THREADPOOL_SIZE=1` **plus one throwaway drained
lookup** (the pool is process-global and initialized at first submit, so it
is pinned at size 1 before any dependent test — a comment-that-is-a-check);
registry and orphan baselines. House rules throughout: `run-until/ticking`
for every DNS wait (a pending request blocks `uv-run 'once` — Q1's
recorded observation makes the ticker mandatory), `(collect)` in every
callback, non-`#f`/non-zero sentinels, per-kind live counts asserted
nonzero mid-test then balanced, literal `(exit ...)` last line.

Key rows: numeric v4/v6 single-record success (the v6 row is the
portability trap's live check); unpinned-socktype multi-entry chain
(**set-containment, never order** — Q4: Darwin answers 2 entries
dgram-first with no raw, glibc expectedly 3 including raw); `AF_UNSPEC` +
literal → single family; non-numeric under `numeric-host` → `'EAI_NONAME`
+ `'()`; fresh-records-per-run (ADR-0009 pattern); request live in flight
and freed before `on-complete` (in-callback live-count recording);
resubmit-from-callback chain; numeric reverse v4/v6; **post-registration
sync-failure abandon via `(uv-getaddrinfo! loop "" "80" …)`** — the idna
`UV_EINVAL` path (§5.5) — plus the garbage-address getnameinfo row
relabeled as pre-registration-guard coverage; cancel rows in the boolean
vocabulary (a tolerant tail-cancel with branch-invariant asserts:
exactly-one-callback, the paired errno consequence per branch, balance;
cancel-after-completion → `#f` with no native call; double-cancel
documented); teardown-with-in-flight (err ∈ {`#f`, `'EAI_CANCELED`},
exactly one callback, balanced); a raising `on-complete` →
`&uv-callback-error` via `uv-run` (proving the `registry-loop-of` path
found a loop no `handle-loop` could have); synthetic-chain rows for the
skip policy and NULL `ai_addr`; balance epilogue; the `uv-loop-close!`
pending-error re-raise row (§6).

**`tests/test-addrinfo.sps`** — pure record + symbolic-hints validation
under `CHEZ_LIBUV_SHIM=/nonexistent`; added to `PURE_TESTS` (deliberate
explicit edit).

**Corrected mutation-log expectations** — the adversarial reviews caught
four panel predictions that would have failed the watched-to-fail
discipline at log time; the *corrected* oracles are the ones to record:

- *Ten-name freeze* (drop `'getaddrinfo` from `dispatcher-names`): caught
  by the two widened literal rows (test-loop.sps:193-195,
  test-native.sps:1124-1126) failing by name plus `'unknown-dispatcher` at
  `(libuv dns)` import — **NOT** by `install-callback-dispatchers!`'s
  length validation, because handles.sls builds its install alist by
  mapping the same list, so both sides shrink together and the validation
  passes.
- *Offline-ban watchdog*: a **value-level** check that the suite helper's
  computed `ai_flags` has the `numeric-host` bit — the
  resolve-a-`.invalid`-name variant *passes* under the mutation on any
  networked machine (NXDOMAIN maps to the same `EAI_NONAME` the row
  asserts; measured).
- *Dropped `uv_freeaddrinfo`*: no suite assertion possible — gate-caught
  (valgrind definite leak, exit 9; the chain becomes unreferenced at
  exit), logged as gate-caught with the output pasted.
- *Offset swap (`ai_addr`/`ai_canonname`)*: fails by name **only because**
  `sockaddr->address-string` refuses zero pointers (§5.1) — without that,
  the swapped copy-out is a SIGSEGV on the NULL canonname slot.
- *Trampoline cross-pairing*: logged as "failure mode varies" (garbage
  register / interior-pointer free — §5.4), with the dispatcher kind-check
  arm as the *designed* defense, plus registry/counter balance rows and
  valgrind as backstop — not the panel's predicted `'iterations-exhausted`.

**Memory gates.** Linux valgrind leg green with no recipe change expected:
worker stacks/TLS/nss are still-reachable-or-possibly-lost, outside the
definite-only gate, and the numeric-only suite never dlopens NSS modules;
Q2 is the evidence this is not a hope, and any suppression decision is made
there, not in red CI. macOS ASan arm unchanged (`detect_leaks=0`;
addressability stays live, so a copy-after-free of the chain still traps).

---

## 10. Stage 0 spike (`spike/dns/`, findings in `spike/dns/FINDINGS.md`)

House format: numbered questions, verbatim commands and output, every
experiment run twice, byte-differences named. The filter from v0.1 applies:
a plain code fact of the pinned submodule is settled by citation (§7); only
properties emerging from the Chez × libuv × libc × valgrind *interaction*
are spiked. Four questions survive it.

- **Q1 — threadpool workers × Chez GC × re-entrancy × loop-liveness.**
  10k numeric lookups; `(collect)` plus a resubmission from inside every
  callback; locked-entry-point stability compared before/after (v0.1 Q1's
  exact check, on the two new trampoline shapes). Recorded as observations,
  not separate questions: `uv-run 'once` blocks on a pending request
  (→ `run-until/ticking` mandatory for every DNS wait); Chez `string`
  argument marshalling — `#f`→NULL, UTF-8 transcoding, embedded-NUL
  truncation (the measurement behind §4.1's NUL refusal).
  *Venue:* dev machine ×2, plus one run per CI OS (workers × signal masks
  is per-OS). *Exit:* two byte-identical 10k runs; CI runs recorded.
- **Q2 — valgrind's and ASan's view of unjoined workers.** The Q1 script
  (reduced) under the *exact* `test-memory` invocation. *Venue:* the CI
  spike branch for the Linux valgrind leg — valgrind does not exist on this
  Darwin/arm64 dev machine, so CI logs are the recorded evidence — and the
  local macOS ASan arm. *Exit:* Linux exit 0 under the definite-only gate,
  twice; every definite block attributed (glibc-internal vs ours) before
  the ADRs flip; the suppression decision (targeted file vs none) made
  here, not in red CI.
- **Q3 — cancel race histogram.** `UV_THREADPOOL_SIZE=1` via suite-prologue
  `putenv` (propagation already confirmed empirically; the spike records it
  formally), 1000 trials of blockers-plus-tail cancel, branch histogram,
  plus a default-pool control. *Exit:* the cancelled branch dominates at
  pool 1; both branches show exactly-one-callback. This licenses the
  tolerant cancel test; the recorded fallback if pool pinning is refuted is
  32 blockers at default pool with the same branch-invariant asserts.
- **Q4 — hermetic determinism matrix on both libcs** (CI spike branch):
  `AI_NUMERICHOST` v4/v6 literals; `AI_NUMERICHOST` + non-numeric →
  `EAI_NONAME` (the macOS half already measured); unpinned-socktype chain
  shape per OS (macOS: 2 entries, dgram-first, no raw; glibc expected 3
  incl. raw — assertions written as set-containment, never order);
  `AF_UNSPEC` + literal → single family; numeric reverse cases; and one
  scoped-literal row feeding ADR-0012's documented-drop text. *Exit:* every
  cell identical across runs on one OS; cross-OS differences enumerated
  exactly.

**Spike exit flips ADR-0011..0013 and the ADR-0008 amendment to Accepted**
on the recorded evidence, per the status convention in §2.

---

## 11. Milestone sequence

| Stage | Focus | Exit criterion |
|---|---|---|
| 0a | Branch `feat/dns-v0.2`; this spec + ADR-0011..0013 (Proposed) + the ADR-0008 amendment draft | Docs committed |
| 0b | Spike Q1–Q4 (`spike/dns/`), incl. CI spike-branch runs | `FINDINGS.md` evidence recorded twice; ADRs flipped Accepted |
| 1 | Shim + constants.sls: all new entries, two counter classes | test-native presence/distinctness rows green; `check-prod` green |
| 2 | native.sls: raw bindings, helpers (`c-uptr-ref`, `sockaddr->address-string`), two trampolines, ten names, wrappers; the two hard-coded eight-name tests updated (watched to fail first); `fill-sockaddr!`/`align-16` lifts | Suite green; mutation rows logged |
| 3 | handles.sls: `complete-request!` generalization (`registry-loop-of` + extras), exports, `abandon-request!` lift, `cancel-requests-for-loop!`; loop.sls teardown integration | TCP/timer suites still green (equivalence guarded); teardown rows green |
| 4 | `(libuv private addrinfo)` + `(libuv dns)` getaddrinfo path (validation, hints, dispatcher, chain walk); hermetic + synthetic-chain tests; `PURE_TESTS` edit | Forward-lookup rows + test-addrinfo green |
| 5 | getnameinfo path + `uv-cancel!` + cancel/teardown/lifecycle/counter tests | Full test-dns green; `make test-memory` green on CI |
| 6 | `uv-loop-close!` pending-error re-raise (TDD) + comment rewrite; facade + test-facade; README.org DNS table + threadpool/NULL-hints/scope-ID notes; CHANGELOG 0.2.0; Akku.manifest → 0.2.0 (manual — `check-pins` does not cover it); mutation logs complete | CI green both legs; tag v0.2.0 per the closing ritual |
