# Design Spec: chez-libuv v0.3 — Process

- **Date:** 2026-08-21
- **Status:** Proposed — pending Stage 0 spike (`spike/process/`, §10) and
  spec review; decisions marked *(spike-gated)* are resolved by evidence
  before their ADRs are accepted
- **Supersedes:** nothing. Refines the
  [v0.1 design spec](2026-08-18-chez-libuv-v0.1-design.md), the
  [v0.2 design spec](2026-08-21-chez-libuv-v0.2-dns-design.md), and
  `.plans/chez-http-server-architecture.md` §1 (the `process.sls` box that
  layout has carried since the start)
- **Scope:** v0.3 of the Chez Scheme binding for libuv: `(libuv process)`,
  a minimal `(libuv pipe)`, and the `(libuv stream)` extraction both require

This document specifies the v0.3 delta over the shipped v0.2 binding (loop,
TCP, timers, DNS — tagged 2026-08-21). Everything the v0.1 and v0.2 specs say
remains in force except where a section below explicitly amends it. Each new
decision is backed by an ADR under `.plans/decisions/`; vendored-libuv facts
are cited against the pinned v1.52.1 submodule and become code-comment
citations at implementation time (§7).

---

## 1. Goal and non-goals

**Goal.** Bind libuv's child-process surface — `uv_spawn`,
`uv_process_kill`, `uv_kill`, `uv_process_get_pid` — as a new R6RS library
`(libuv process)`, with full stdio control including pipes, in the
established house style: a thin legible mirror of libuv's own verbs, records
and Scheme values only at the public boundary, no pointer ever visible
outside `private/`. Pipe stdio requires `uv_pipe_t`, which does not exist in
the binding yet, so v0.3 also ships a deliberately minimal `(libuv pipe)`
(`uv_pipe_init` only) and performs the one honest refactor both need:
extracting the stream verbs from `(libuv tcp)` into a new `(libuv stream)`
whose gating is stream-kind, not TCP-kind. This is the binding's first
subprocess machinery and its first interaction with the host's child-reaping
signals; both firsts are governed by new ADRs and gated on a Stage 0 spike
(§10).

**Non-goals.**

- **No `uv_signal_t`.** Handling signals *in* the event loop (trap
  SIGTERM/SIGINT, graceful-shutdown patterns) is a recorded future-milestone
  candidate. v0.3 binds only the signal-*sending* side that process control
  needs (`uv-process-kill!`, `uv-kill!`).
- **No pipe `bind`/`connect`/`listen`.** Named-pipe / unix-socket IPC
  servers are a separate milestone; `make-uv-pipe` exists in v0.3 so that
  `uv_spawn` can open it as a child's stdio end, and for no other reason.
  `uv-listen!`/`uv-accept!` stay TCP-only.
- **No `ipc=1` fd-passing.** `uv_pipe_init`'s ipc flag is always 0. Sending
  handles over pipes (`uv_write2`) is out.
- **No `uv_disable_stdio_inheritance`, no `UV_NONBLOCK_PIPE`.** The former
  is a best-effort global libuv itself hedges on; the latter can drop data
  by design. Neither can be asserted deterministically.
- **Windows flags out, per ADR-0004.** `UV_PROCESS_WINDOWS_*` are
  unrepresented in the options vocabulary; Windows remains deferred, not
  designed out.
- **No filesystem, no UDP.** v0.3 adds exactly process + minimal pipe.
- **No shell-out convenience.** No `run-command`-style wrapper that spawns,
  collects output, and returns strings. That is an opinionated abstraction
  the v0.1 charter leaves to layers above; the primitives compose.

---

## 2. Decisions summary

| # | Decision | ADR |
|---|----------|-----|
| 1 | Stream verbs move to `(libuv stream)`; records gain a `uv-stream-record` intermediate type; pipe and tcp are its children | ADR-0014 (new) |
| 2 | Spawn inputs are co-allocated into one foreign block, freed unconditionally the moment `uv_spawn` returns; failure-path cleanup strategy | ADR-0015 (new, *spike-gated* on SQ1) |
| 3 | Signals cross the boundary as a closed symbol set from the shim table; exit delivery is `(exit-status term-signal)` results, never conditions; setuid/setgid are bound and tested via an opt-in root lane | ADR-0016 (new) |
| 4 | The trampoline set grows ten → twelve (`exit`, `walk`); the two frozen test literals widen watched-to-fail | ADR-0008 (amend) |
| 5 | `uid`/`gid` option presence implies `UV_PROCESS_SETUID`/`SETGID` — the flag+field pair is never split at the public boundary | ADR-0016 |
| 6 | Pipe direction vocabulary is `to-child`/`from-child`/`duplex`, not libuv's child-perspective `READABLE`/`WRITABLE` names | ADR-0016 |

Existing ADRs applied without amendment: 0002 (direct FFI — `uv_spawn` et
al. are called from Scheme, the shim gains only constant rows), 0005 (every
new sizeof/offsetof/flag/signal is a shim table row), 0006 (spawn/kill
errors are errno symbols), 0007 (the process handle is explicitly closed,
even after exit; teardown sweeps it), 0009 (argv/env/cwd/options copied at
the boundary in both directions), 0011 (its request-specific rules don't
apply — a process is a handle, not a handle-less request — while the
registry-keeps-the-record-reachable machinery it generalized is reused), 0012 (validators
shared on second use; spawn invents no vocabulary libuv doesn't have).

---

## 3. Module layout (delta)

```
src/libuv.sls                  facade: + (libuv stream), (libuv pipe), (libuv process) blocks
src/libuv/stream.sls           NEW — uv-write!, uv-shutdown!, uv-read-start!, uv-read-stop!
                               moved from tcp.sls, gated on stream-kind
src/libuv/tcp.sls              keeps bind/connect/listen/accept/getsockname/nodelay;
                               re-exports the four stream verbs (importers unchanged)
src/libuv/pipe.sls             NEW — make-uv-pipe
src/libuv/process.sls          NEW — uv-spawn!, uv-process-kill!, uv-kill!,
                               uv-process-pid; exit dispatcher installed
                               at library-body time (dns.sls precedent)
src/libuv/handle.sls           + uv-pipe?, uv-process? beside uv-tcp?
src/libuv/private/handles.sls  uv-stream-record intermediate; uv-pipe-record,
                               uv-process-record children; handle-kinds + counters widen
src/libuv/private/native.sls   exit trampoline (11th); uv_spawn/uv_process_kill/uv_kill/
                               uv_process_get_pid/uv_pipe_init foreign-procedures
src/libuv-shim.c               constant rows only (§5.3)
tests/test-stream.sps          NEW — verb gating across kinds
tests/test-pipe.sps            NEW
tests/test-process.sps         NEW
tests/test-process-setuid.sps  NEW — root lane only, filtered out of TESTS
spike/process/                 Stage 0 spike + FINDINGS.md
```

The kind predicates `uv-pipe?` and `uv-process?` are **defined in
`(libuv handle)`** beside `uv-tcp?` — kind predicates live where the kind
vocabulary lives, and (matching `uv-tcp?` today) they are *not*
re-exported by pipe.sls/process.sls; the facade re-exports them from
`(libuv handle)`.

---

## 4. Public API

### 4.1 `uv-spawn!`

```scheme
(uv-spawn! loop file args on-exit)          ;; options omitted
(uv-spawn! loop file args options on-exit)  ;; options alist
  → process handle record
```

- `loop` — an open loop.
- `file` — the program path, a string. Passed to libuv verbatim; execvp's
  own PATH semantics apply (the binding neither resolves nor validates
  existence — `'ENOENT` comes back from `uv_spawn`).
- `args` — the **complete argv including `argv[0]`**, a non-empty list of
  strings. libuv's own contract (`args[0]` is by convention the program
  path but not enforced); passed through unmodified, so argv[0] tricks
  remain possible. The mirror rule, applied.
- `on-exit` — a procedure `(lambda (exit-status term-signal) ...)` or `#f`
  (the public mirror of libuv's nullable `exit_cb`; reaping happens
  regardless). `#f` is surface-only: the exit trampoline is **always**
  baked into the options block — NULL is never written to
  `options.exit_cb` — and `#f` merely means the dispatcher invokes no
  user callback (§5.4 step 5), so the lifecycle machinery (registry
  lookup, `exited?` flag) runs for every spawn. The argument position is
  always present, so the two arities stay unambiguous, exactly like
  `uv-getaddrinfo!`'s optional hints.

Returns the process record with the child already running. A nonzero
`uv_spawn` raises `&uv-errno-error` (`'ENOENT`, `'EACCES`, `'EPERM`, …)
and leaves nothing half-built (§5.6). The handle is active from birth and
keeps the loop alive until the exit callback has fired (vendor fact V10).

### 4.2 The options alist

Closed key set; an unknown key raises `&uv-invalid-argument` with reason
`'option-unknown` naming the key. Omitted, `#f`, and `'()` options all
mean "defaults" (the hints precedent).

| Key | Value | Absent means | libuv target |
|-----|-------|--------------|--------------|
| `env` | list of `"K=V"` strings | inherit parent environment | `options.env` (NULL) |
| `cwd` | string | inherit cwd | `options.cwd` (NULL) |
| `stdio` | list of stdio specs (§4.3) | all slots ignore | `options.stdio` |
| `detached` | boolean | `#f` | `UV_PROCESS_DETACHED` |
| `uid` | exact integer, 0 ≤ n < 2³² (`'uid-out-of-range`) | flag unset, field zeroed | `UV_PROCESS_SETUID` + `options.uid` |
| `gid` | exact integer, 0 ≤ n < 2³² (`'gid-out-of-range`) | flag unset, field zeroed | `UV_PROCESS_SETGID` + `options.gid` |

- `env` mirrors libuv's own `"K=V"` array format — the binding does not
  invent an alist encoding and does not parse the strings (ADR-0012's
  never-invent rule applied to a value format). Each string is validated
  for embedded NULs (the spike-verified silent-truncation trap); nothing
  else is policed.
- **`uid`/`gid` presence implies the flag.** libuv ignores `options.uid`
  unless `UV_PROCESS_SETUID` is set; the split is a documented footgun and
  the binding closes it — you cannot express "field set, flag clear."
  Setting either as non-root fails at spawn time with `'EPERM` (§9.2).
- `detached` maps to `UV_PROCESS_DETACHED` (child becomes a session
  leader, survives the parent). The handle still keeps the loop alive
  until closed; the documented pattern is spawn-then-`uv-close!`
  immediately, after which the child is never reaped by us (V7). `uv_ref`
  / `uv_unref` remain unbound — nothing in v0.3 needs them.

### 4.3 stdio specs

The `stdio` value is a list of per-slot specs, index = child fd: slot 0 is
stdin, 1 stdout, 2 stderr. Fewer than three specs is fine — libuv itself
pads slots 0–2 to `UV_IGNORE`, and an ignored 0–2 slot reads/writes
`/dev/null` in the child (V4). More than three slots passes extra fds to
the child in order.

| Spec | Meaning | libuv flags |
|------|---------|-------------|
| `ignore` | no fd (0–2: /dev/null) | `UV_IGNORE` |
| `(inherit-fd . n)` | child gets a dup of parent fd *n* | `UV_INHERIT_FD` |
| `(inherit-stream . h)` | child gets a dup of the fd under open stream handle *h* (tcp or pipe) | `UV_INHERIT_STREAM` |
| `(pipe p dir)` | libuv creates a pipe pair; parent end opens into *p* | `UV_CREATE_PIPE` + direction |

The two one-payload specs are **dotted pairs**, `(cons 'inherit-fd 3)`, not
one-element lists; `(pipe p dir)` is a proper 3-list because it carries two.
Amended at implementation time (Task 8) to the spelling the milestone plan's
own test rows and parser already used throughout — the earlier
`(inherit-fd n)` notation in this table was never implemented and never
accepted by the validator.

- In `(pipe p dir)`, `p` must be a pipe from `make-uv-pipe` that is open
  (not closed), belongs to the same loop as the spawn
  (`'pipe-wrong-loop` otherwise), and is **unconnected** — never consumed
  by a previous spawn: `uv_spawn` itself creates the socketpair and
  connects the parent end into `p` (V3). After a successful spawn the
  pipe is a connected stream — read, write, shutdown, close like any
  other. **A failed `uv-spawn!` consumes its pipes too, by policy — not
  uniformly by fact.** Measured only on the exec class
  (`spike/process/FINDINGS.md` SQ1 Observation 3): libuv opens the parent
  ends before it can know whether the exec succeeded, so those pipes are
  genuinely connected (`uv_fileno` rc 0, a real fd) after a failed spawn.
  On the setup class the socketpair fds libuv itself opened are closed
  again inside libuv, before `uv__process_open_stream` ever runs
  (vendor/libuv/src/unix/process.c:1013→1015 — `uv__process_init_stdio`
  failing sends control straight to `error:`; that label's cleanup loop at
  :1082-1085 closes both pipe fds) — those pipes are **not** actually
  connected. The binding still marks **every** consumed pipe connected
  regardless of class: this is conservative policy, not a factual claim
  about the setup class's fds, for the same reason ADR-0015 gives —
  under-reporting connectedness is what would let a later spawn hand libuv
  an already-opened stream, so the uniform, refuses-reuse-either-way
  contract is the safe direction even where it over-reports. Every pipe
  named in a raising spawn's stdio specs therefore refuses reuse
  (`'pipe-already-used`) and must be closed by the caller exactly like any
  other pipe — but a test must **not** assert a real fd behind a pipe after
  a setup-class failure, only after an exec-class one. A spawn that raises
  does not hand its pipes back unused; the recovery pattern is
  close-and-remake, not retry-with-the-same-pipes (§5.6, ADR-0015). Naming
  an already-connected pipe raises `&uv-invalid-argument`
  (`'pipe-already-used`); the record tracks this. Throughout this spec
  "open/closed" is always handle state, "connected/unconnected" always the
  spawn-consumption state.
- `dir` is one of:
  - `to-child` — parent writes, child reads. The stdin shape.
    (= `UV_READABLE_PIPE`, "readable" from the *child's* perspective.)
  - `from-child` — child writes, parent reads. The stdout/stderr shape.
    (= `UV_WRITABLE_PIPE`.)
  - `duplex` — both. (= both flags.)

  This is the one place v0.3 deliberately does not mirror libuv's names:
  `UV_READABLE_PIPE`/`UV_WRITABLE_PIPE` are named from the child's
  perspective, which is libuv's single most direction-confusing
  vocabulary, and the failure mode of copying it is a silent direction
  bug. The mapping above is stated in the module header and in ADR-0016.
- Spec validation is closed-set with kept-raising else arms: unknown spec
  shape → `'stdio-spec-unknown`; non-fixnum fd → `'stdio-fd-not-an-fd`;
  closed/wrong-kind handle in `inherit-stream` → the usual kind/state
  conditions.

### 4.4 The exit callback contract

`on-exit` receives exactly two arguments, both already-copied Scheme
values, delivered from the exit dispatcher under the standard guarded seam:

- `exit-status` — exact integer. libuv semantics, documented prominently:
  `WEXITSTATUS` if the child exited normally, **`0` if it was killed by a
  signal** (V5). Killed-by-SIGTERM arrives as `(0 sigterm)`, not `(-1 …)`.
- `term-signal` — `#f` if the child exited normally; otherwise the signal
  as a symbol (`'sigterm`, `'sigkill`, …) via reverse lookup over the same
  shim signal table, or the **raw exact integer** if the child died from a
  signal outside the bound set — information is never dropped.

These are results, not errors — the UV_EOF precedent: success-shaped
values get their own delivery and are never routed through
`&uv-errno-error`. There is no error argument; `uv_exit_cb` has none.

Exit does not close (§6). Pipe EOF and exit ordering is not guaranteed
relative to each other (V5); consumers wait for both independently, and so
do the tests (§9.2).

### 4.5 `uv-process-kill!`, `uv-kill!`, `uv-process-pid`, `uv-process?`

```scheme
(uv-process-kill! proc sig)   ;; by handle — uv_process_kill
(uv-kill! pid sig)            ;; by raw pid — uv_kill
(uv-process-pid proc)         ;; → exact integer, uv_process_get_pid
(uv-process? x)               ;; → boolean (defined in (libuv handle), §3)
```

- `sig` is a symbol from the closed set `sigterm sigkill sigint sighup
  sigquit sigusr1 sigusr2 sigcont sigstop`, **or the exact integer `0`** —
  the POSIX liveness probe (`kill(pid, 0)`, V9), documented as such. Signal
  numbers come from the shim table (ADR-0005; SIGTERM's value is never
  written in Scheme source). Unknown symbols and other integers raise
  `'signal-unknown`. The symbol→int validator lives in `process.sls`; per
  the PR #4 rule it lifts to `(libuv private native)` on its second user.
- Both raise `&uv-errno-error` on failure (`'ESRCH`, `'EPERM`, …); success
  returns unspecified.
- **Pid validity ends at the exit callback.** The child is reaped by the
  time `on-exit` runs, so a subsequent kill/probe races with pid reuse —
  it will usually raise `'ESRCH`, but the binding cannot promise the
  signal won't land on a recycled pid. The module header documents this;
  tests do not signal after exit (§9.2).
- `uv-process-pid` requires an open handle (kind check, then state check);
  it is valid between spawn and close, including after exit.

### 4.6 `(libuv pipe)` and the stream verbs

```scheme
(make-uv-pipe loop)   ;; uv_pipe_init(loop, ptr, 0) → pipe handle record
(uv-pipe? x)          ;; → boolean (defined in (libuv handle), §3)
```

`make-uv-pipe` follows `make-uv-tcp` exactly: `ensure-native-loaded!` →
`require-open-loop` → `alloc-zeroed (uv-handle-size (uv-pipe-type))` →
guarded init → record → `registry-register!` → counter. A fresh pipe is
unconnected — its only v0.3 purposes are to be handed to `uv-spawn!` in a
`(pipe p dir)` spec, or closed. Stream verbs on an unconnected pipe
surface whatever errno libuv returns (`'EBADF`/`'ENOTCONN`-class; pinned
by a test — bind what you test, §9.3).

The four stream verbs — `uv-write!`, `uv-shutdown!`, `uv-read-start!`,
`uv-read-stop!` — move to `(libuv stream)` and accept any open stream-kind
handle (tcp or pipe). Their signatures, callback contracts, copy
discipline, and free-before-on-complete ordering are unchanged from the
v0.1 spec; only the gating predicate widens (`require-open-stream`
replacing `require-open-tcp`, kind check first, state check second).
`(libuv tcp)` re-exports all four, so existing importers compile
unchanged; the facade re-exports them from `(libuv stream)`.

### 4.7 Facade and conditions

`src/libuv.sls` gains three name-by-name export blocks (`--- Stream ---`,
`--- Pipe ---`, `--- Process ---`) in house style, plus the two new kind
predicates in the handle block; generic names (`uv-close!`, `uv-handle?`)
are not duplicated. No new condition types: `&uv-invalid-argument`,
`&uv-handle-closed`, `&uv-errno-error` cover every v0.3 failure with new
reason symbols only. The closed v0.3 reason-symbol vocabulary, in full —
the validators implement exactly this list and §9.2's validation walk
drives every row:

| Symbol | Raised when |
|--------|-------------|
| `'file-not-a-string` | `file` not a string |
| `'args-not-a-string-list` | `args` not a non-empty list of strings |
| `'embedded-nul` | a NUL inside `file`, an `args`/`env` string, or `cwd` |
| `'option-unknown` | options alist key outside the §4.2 set |
| `'env-not-a-string-list` | `env` present but not a list of strings |
| `'cwd-not-a-string` | `cwd` present but not a string |
| `'detached-not-a-boolean` | `detached` present but not a boolean |
| `'uid-out-of-range` / `'gid-out-of-range` | outside 0 ≤ n < 2³² |
| `'stdio-not-a-list` | `stdio` present but not a list of specs |
| `'stdio-spec-unknown` | a spec matching no §4.3 form (incl. bad `dir`) |
| `'stdio-fd-not-an-fd` | `inherit-fd` value not a nonnegative fixnum |
| `'pipe-already-used` | `(pipe …)` names a connected pipe |
| `'pipe-wrong-loop` | `(pipe …)` names a pipe from another loop |
| `'signal-unknown` | `sig` outside the §4.5 symbol set and not `0` |
| `'on-exit-not-a-procedure` | `on-exit` neither a procedure nor `#f` |

Wrong-kind and closed-handle arguments raise the existing
`&uv-invalid-argument`/`&uv-handle-closed` shapes the stream verbs already
use; they are not new vocabulary.

---

## 5. Internals

### 5.1 handles.sls: the stream record hierarchy (ADR-0014)

R6RS record inheritance gains one intermediate level:

```
uv-handle-record                      (ptr, kind, loop, state, on-close)
├── uv-stream-record                  NEW (read-buf, read-buf-len, reading,
│                                          on-data, on-eof, on-error)
│   ├── uv-tcp-record                 (on-connection + tcp-specific fields)
│   └── uv-pipe-record                NEW (connected? flag)
├── uv-timer-record
└── uv-process-record                 NEW (on-exit, exited?)
```

- `uv-stream-record` hoists the complete stream-generic read-path field
  set from today's tcp record (handles.sls:297-309) — everything except
  `on-connection`, which stays on the tcp child (listen/accept remain
  TCP-only). The alloc/read dispatchers and `free-read-buffer!` arms move
  from `uv-tcp-record?` checks to `uv-stream-record?` checks — the
  natives underneath were always `uv_stream_t`-generic; this closes the
  gap at the record layer.
- A process is a handle, not a stream: `uv-process-record` is a direct
  child of `uv-handle-record`. Its single callback field `on-exit` is
  stored **before** `uv_spawn` is called (the callback travels inside the
  options struct, so refusal-must-not-clobber does not apply — there is
  nothing to clobber on a fresh record; the uv-listen! store-before
  precedent).
- `uv-pipe-record.connected?` starts `#f`, flips when a spawn consumes
  the pipe in a `(pipe …)` spec. It exists solely to make
  `'pipe-already-used` raisable before allocation.
- `uv-process-record.exited?` starts `#f`, set by the exit dispatcher
  (§5.4 step 4) — the observable behind §9.2's lifecycle scenarios
  (close-after-exit, kill-before-exit-only discipline).
- `handle-kinds` widens `'(timer tcp)` → `'(timer tcp pipe process)`
  (handles.sls:396) so the teardown sweep closes both new kinds; the close
  dispatcher gains arms for their counters, and pipe buffers free through
  the same stream arm as tcp's.
- New counters: `count-pipe-new!/free!`, `count-process-new!/free!`, with
  `live-counts` rows — every suite's balance assertions extend to them.

### 5.2 native.sls: the trampoline set grows to twelve

- `dispatcher-names` (native.sls:854, append-only, order is contract)
  gains `exit` and `walk`: ten → twelve names. The two frozen ten-name
  literals — tests/test-loop.sps and tests/test-native.sps — are widened
  first, watched to fail (ADR-0008 amendment procedure, second
  application).
- The `exit` foreign-callable has libuv's exact signature
  `(uptr integer-64 int) -> void` (`uv_exit_cb`: handle, int64_t
  exit_status, int term_signal) — a foreign type signature no existing
  trampoline has, so it cannot share one. Body is mechanical: fire-time
  `(dispatcher-ref 'exit)`, no policy. Created with the other ten, locked
  in `trampolines-locked`, entry point taken once and baked into the
  options block by the spawn path — it never leaves native.sls otherwise.
- The `walk` foreign-callable has libuv's exact signature
  `(uptr uptr) -> void` (`uv_walk_cb`: handle, void *arg) — a foreign type
  signature no existing trampoline has either, so it is a twelfth callback
  type rather than a reuse of `exit`'s or any other. Unlike every other
  trampoline, `walk` fires **synchronously**: only for the duration of a
  `uv_walk` call, on the caller's own thread, never from `uv_run`. Its
  only v0.3 consumer is the §5.6 failure path's queue-membership query,
  `(handle-in-loop-queue? loop handle)`, which lives in `handles.sls`
  beside the registry it complements — the helper and its module-level
  query cell call native's `uv-walk-native`, and handles.sls EXPORTS the
  walk dispatcher (a closure over that cell) without installing it. The
  install happens at `(libuv process)`'s library-body time through
  `install-dispatch-procedure!` — the §5.4 late-install seam, exactly as
  `exit` — so the trampoline body carries no policy and a program that
  never imports `(libuv process)` keeps the raising stub for `walk` as it
  does for `exit` (ADR-0015). Created with the other eleven, locked in `trampolines-locked`,
  entry point taken once and baked into a `uv-walk-native` wrapper — it
  never leaves native.sls otherwise.
- New foreign-procedures, all direct FFI (ADR-0002): `uv_spawn`
  (`(uptr uptr uptr) -> int`), `uv_process_kill` (`(uptr int) -> int`),
  `uv_kill` (`(int int) -> int`), `uv_process_get_pid` (`(uptr) -> int`),
  `uv_pipe_init` (`(uptr uptr int) -> int`), `uv_walk`
  (`(uptr uptr uptr) -> void`). No wrapper C function exists or is
  permitted.

### 5.3 Shim and constants additions (ADR-0005)

New rows in `chez_uv_constant_table`, each backed by the real headers and
each deletion mutation-tested against a named test:

- Type tags: `UV_PROCESS`, `UV_NAMED_PIPE` (handle sizes keep coming from
  `uv_handle_size` at runtime, as for tcp/timer).
- `SIZEOF_UV_PROCESS_OPTIONS_T`; `OFFSETOF_UV_PROCESS_OPTIONS_T_` ×
  {`EXIT_CB`, `FILE`, `ARGS`, `ENV`, `CWD`, `FLAGS`, `STDIO_COUNT`,
  `STDIO`, `UID`, `GID`}.
- `SIZEOF_UV_STDIO_CONTAINER_T`; `OFFSETOF_UV_STDIO_CONTAINER_T_FLAGS`,
  `OFFSETOF_UV_STDIO_CONTAINER_T_DATA` — the union: `fd` is written as a
  32-bit int and `stream` as a pointer at the same data offset (V2).
- Process flags: `UV_PROCESS_SETUID`, `UV_PROCESS_SETGID`,
  `UV_PROCESS_DETACHED`.
- Stdio flags: `UV_IGNORE`, `UV_CREATE_PIPE`, `UV_INHERIT_FD`,
  `UV_INHERIT_STREAM`, `UV_READABLE_PIPE`, `UV_WRITABLE_PIPE`.
- Signals (from `<signal.h>`): `SIGTERM`, `SIGKILL`, `SIGINT`, `SIGHUP`,
  `SIGQUIT`, `SIGUSR1`, `SIGUSR2`, `SIGCONT`, `SIGSTOP`.

Every name joins constants.sls's required-names walk — a missing row fails
init closed with `&uv-constant-unavailable`. Struct fields are poked via
offset arithmetic on `alloc-zeroed` blocks, never a declared ftype (the
addrinfo field-order lesson stands).

### 5.4 The exit dispatcher (in process.sls)

Installed at `(libuv process)` library-body time via
`install-dispatch-procedure!` — the dns.sls late-install seam, second
application. A program that never imports the library keeps the contained
raising stub. The dispatcher body, in order:

1. `registry-ref` the ptr; orphan → `record-orphan-callback!`, done.
2. Kind-check the record is a process record (mismatch raises into the
   seam's containment).
3. Copy the two ints into Scheme values; map `term_signal` 0 → `#f`,
   known int → symbol (reverse table), unknown int → itself.
4. Set the record's `exited?` flag (§5.1) — the observable behind the
   §9.2 lifecycle scenarios.
5. If `on-exit` is `#f`, done. Otherwise the user callback runs **last**,
   under `dispatch-guarded` (clause `#t`, store-and-reraise, loop stopped
   — the measured exit-255 rule).

Nothing is freed here: exit stops the handle; the close dispatcher remains
the only place process memory is freed (ADR-0007).

### 5.5 Spawn flow and co-allocation (ADR-0015)

The two iron rules, verbatim from every module header: every argument is
validated before the first allocation, and a failed native call leaves
nothing half-built.

1. **Validate everything**: open loop; `file` a string, NUL-checked;
   `args` a non-empty list of strings, each NUL-checked; options alist
   closed-set walked (`env` strings NUL-checked, `cwd` NUL-checked,
   `uid`/`gid` per the §4.2 range, stdio specs per §4.3 including every
   pipe open, unconnected, and belonging to this loop —
   `'pipe-already-used`/`'pipe-wrong-loop`); `on-exit` a procedure or
   `#f`.
2. **Allocate the handle**: `alloc-zeroed (uv-handle-size
   (uv-process-type))`, build the record (on-exit stored now), do **not**
   register yet.
3. **Build one co-allocated options block**: a single `foreign-alloc` of
   computed total size holding — in order — the `uv_process_options_t`,
   the `uv_stdio_container_t` array, the argv pointer array
   (NULL-terminated), the env pointer array (NULL-terminated, only if
   `env` present), and every string's UTF-8 bytes (NUL-terminated),
   with internal pointers fixed up. `exit_cb` gets the exit trampoline's
   entry point unconditionally (§4.1 — NULL is never written); flags are
   OR'd from the shim values only, so libuv's unknown-flag assert is
   unreachable from Scheme (V8).
4. **Call `uv_spawn`.** libuv consumes the entire block synchronously —
   posix_spawn/fork+exec happen inside the call; only `exit_cb` and `pid`
   are copied into the handle (V1). Therefore:
5. **Free the options block unconditionally, immediately** — one alloc
   site, one free site, both paths, mirroring the uv-write! discipline.
6. On rc 0: `registry-register!` ptr `'process` loop record,
   `count-process-new!`, mark every consumed pipe connected, return the
   record. On rc ≠ 0: §5.6, then `uv-check`-style raise.

The block's layout arithmetic (align pointers to word size; strings
packed) is pinned by a test that spawns with multi-arg argv + env + cwd +
three stdio slots simultaneously and asserts every value arrived in the
child (§9.2 — the argv/env/cwd scenario is the mutation target for every
offset row).

### 5.6 The spawn failure path *(SQ1: answered — ADR-0015)*

**There is no single failure strategy.** SQ1 measured two failure classes
with opposite correct cleanups, on both platforms
(`spike/process/FINDINGS.md` SQ1):

- an **exec** failure (the child's `execvp` fails; the errno returns over
  libuv's error pipe) falls off the end of `uv_spawn`
  (vendor/libuv/src/unix/process.c:1073) with the handle **still linked into
  `loop->handle_queue`** — measured `uv_walk` visits it, `uv_loop_close`
  answers `EBUSY`. `uv_close`-then-free is correct; direct `foreign-free`
  leaves the loop permanently `EBUSY` and a dangling queue node the next
  spawn writes through (402 valgrind errors, `definitely lost: 576 bytes in
  2 blocks`, against 0 errors for the close path in the same job);
- a **stdio-setup** failure leaves through the `error:` label
  (process.c:1075-1076), which has already unlinked the handle. Direct
  `foreign-free` is correct; `uv_close` there **silently splices a
  later-registered live handle out of the loop's handle queue** and still
  returns `uv_loop_close` 0 (`late handle survived #f`).

So the failure path is **class-dependent**, and the class is decided by a
runtime property, **never by the errno**: whether the loop still owns our
handle. FINDINGS' rule — "Ask the loop, don't guess" — is ADR-0015's
decision; the errno sets of the two classes overlap (`UV_ENOMEM` and
`EMFILE`/`ENFILE` arise on both sides of the fork), and SQ1 measured only
`ENOENT` and `EINVAL`, so no errno table can carry this. The measured
instrument is `uv_walk`, adopted as the twelfth locked trampoline (§5.2),
installed as `walk` in `dispatcher-names`; ADR-0015 records the decision
and keeps the unmeasured `handle_queue` back-pointer read on file as the
rejected alternative. Stage 5 pins `uv_walk` with a test that drives
**both** classes (`'ENOENT`, and `(inherit-stream h)` on an unconnected
stream → `EINVAL`, process.c:226).

The invariants either way: the options block is already freed (step 5), no
record escapes, no `on-exit` can fire, and the raise carries the errno
symbol. Two refinements ADR-0015 adds, because the close protocol is this
binding's and not libuv's: the exec-class arm **must** register the record
before `uv_close`, since `close-dispatch` is registry-driven and the only
place a handle pointer is freed (handles.sls:872-885) — so that arm's free
is asynchronous, completing on the caller's next `uv-run` or at teardown,
exactly like every other `uv-close!` — and the path asserts
`uv_process_get_pid` reads 0 before choosing an arm, which fails loudly on
the one state the spike did not measure (exec succeeded, a later
`uv__process_open_stream` failed: handle unlinked *and* started, child
alive), a state `'pipe-already-used` forecloses.

**Pipes named in `(pipe …)` specs are consumed by a failed spawn.** §5.6's
earlier expectation that "our pipe records remain consistently unconnected
and closeable" is **refuted**: only the *closeable* half held. libuv creates
the socketpairs before forking and opens the parent ends regardless of
whether the exec succeeded, so `uv_fileno` goes from `EBADF` to a real fd
across a failed spawn (SQ1 Observation 3). The contract, per the S6
no-auto-close precedent (handles.sls:838-840): the failure path **marks
every consumed pipe connected and leaves it open**, and the caller closes it
like any pipe (§4.3). Not closing leaks one fd per slot per attempt —
measured, parent-end fd `9 / 606` over 300 rounds (Linux 12 → 611), 600
handles left open, with no `EMFILE` to announce it.

---

## 6. Exit, close, and teardown semantics

- **Exit and close are two distinct events** (V5). `on-exit` firing stops
  the handle but does not close it; the caller must still `uv-close!` the
  process record — typically from inside `on-exit` — before its memory is
  reclaimed. This is a documented API contract in the module header,
  README, and ADR-0007's orbit.
- An un-closed process handle is caught exactly like an un-closed tcp
  handle: `uv-loop-teardown!`'s close sweep (its kind is in
  `handle-kinds`), debug counters, and the valgrind lane.
- An active (spawned, un-exited) process handle keeps the loop alive:
  `uv-run 'default` does not return while a child is unreaped (V10).
- Closing a live process handle does not kill the child — it stops
  watching it; the child continues and is never reaped by us. Legal, and
  the detached pattern depends on it; documented beside `detached`.
- Kill after exit races pid reuse (§4.5); kill before exit is the
  supported path.
- `uv-loop-close!`'s re-raise-pending-callback-error obligation (the v0.2
  rule) applies to exit-dispatcher errors unchanged.

---

## 7. Verified vendor facts (pinned libuv v1.52.1)

Each becomes a code-comment citation at implementation time; the spike
re-verifies V1 and V5 behaviorally.

- **V1 — spawn consumes options synchronously.** `uv_spawn` copies
  `exit_cb` into the handle (src/unix/process.c:1054), creates stdio
  pipes, and execs via posix_spawn or fork inside the call;
  `file`/`args`/`env`/`cwd`/`stdio` are dereferenced only during the call.
  The options block is freeable the moment it returns.
- **V2 — stdio container layout.** `uv_stdio_container_t` is
  flags + union {stream ptr, int fd}; on LP64 the union sits at offset 8,
  fd written as 32-bit int, stream as pointer (include/uv.h:1031ff).
  Offsets come from the shim regardless.
- **V3 — CREATE_PIPE connects the parent end.** The pipe handle must be
  `uv_pipe_init`'d and unconnected (no fd yet, §4.3 vocabulary);
  `uv_spawn` builds the socketpair and opens the parent end into it.
  Direction flags are from the child's perspective (docs/src/process.rst;
  include/uv.h stdio flags).
- **V4 — short stdio is padded.** `stdio_count` < 3 is padded internally
  to 3 × `UV_IGNORE`; ignored slots 0–2 map to `/dev/null`
  (src/unix/process.c).
- **V5 — exit semantics.** `exit_status` = `WEXITSTATUS` on normal exit,
  else 0; `term_signal` = `WTERMSIG` on signal death, else 0
  (src/unix/process.c:166-174). exit_cb fires on reap; pipe EOF ordering
  relative to exit is unguaranteed. exit stops but does not close the
  handle.
- **V6 — child-exit detection differs by platform, invisibly.** macOS/BSD:
  kqueue `EVFILT_PROC`/`NOTE_EXIT`, no SIGCHLD involvement. Linux: an
  internal unref'd SIGCHLD watcher; **application code must not install
  its own SIGCHLD handling or `waitpid(-1, …)`** — a stolen wait makes
  libuv drop the exit silently (process.c:142-144). This is SQ2's
  subject.
- **V7 — DETACHED.** `setsid`-based; on macOS the posix_spawn path gates
  on ≥ Catalina and falls back to fork/exec — transparent to callers.
  A detached, closed-immediately child is never reaped by us.
- **V8 — flags are asserted.** `uv_spawn` aborts (debug builds) on
  unknown flag bits; the binding can only ever OR the three bound flags,
  so the assert is unreachable from Scheme.
- **V9 — kill is kill(2).** `uv_process_kill` is literally
  `uv_kill(process->pid, signum)` on Unix; signal 0 is the standard
  liveness probe. `uv_process_get_pid` reads `handle->pid`; `uv_pid_t` is
  `pid_t`.
- **V10 — a spawned handle is active and ref'd.** `uv_spawn` starts the
  handle (`uv__handle_start`, src/unix/process.c); an active process
  handle participates in the loop's ref count like any handle, so
  `uv_run 'default` does not return while a spawned child is unreaped
  (docs/src/process.rst). Exit stops the handle (V5); only then can the
  loop drain naturally.

---

## 8. GC and memory invariants (delta over v0.1 §10, v0.2 §8)

- The locked-object set grows by exactly two (the `exit` and `walk`
  trampolines) and remains constant per process — ADR-0008's amended
  invariant, now twelve.
- The options block is the only new foreign allocation kind: one alloc
  site (spawn step 3), one free site (spawn step 5), counted under a new
  debug counter pair so `live-counts` catches an escape.
- No Scheme heap pointer ever enters the options block — every string is
  copied to foreign memory (ADR-0009); everything delivered to `on-exit`
  is a fresh Scheme value copied before anything else happens.
- The process record is kept reachable by its registry entry alone
  (ADR-0007's registry machinery) — no per-spawn locks, no guardians.
- Pipe read buffers follow tcp's exact lifecycle through the shared
  stream arms (allocated on first read-start, freed in the close
  dispatcher).
- Every timer/exit/read callback in the test suites calls `(collect)`
  (the S11 discipline); the spike additionally hammers spawn/exit/pipe
  delivery under per-callback collects (SQ3).

---

## 9. Testing strategy (delta)

### 9.1 Harness rules

- All waits are `run-until/ticking` with iteration caps — never
  wall-clock, and a child-exit wait always uses the ticking variant (a
  blocked bare `'once` after activity can return early; deflake lesson).
- **Child-program allowlist**: `/bin/sh`, `/bin/cat`, and `/usr/bin/id`
  (root lane) — present at those absolute paths on both CI targets by
  platform convention (POSIX itself does not fix the `sh` pathname) —
  always by absolute path, including inside `sh -c` payloads (shell
  builtins excepted). No PATH-dependent spawns in tests. No network. No
  `sleep`.
- **EOF-vs-exit ordering is never asserted** — both orders are legal
  (V5); every test that involves both waits for both independently.
- Sentinels are symbols, never `#f`/0; counter-balance and
  registry-balance rows close every suite.

### 9.2 test-process.sps scenarios (normal suite)

- Exit-code delivery: `sh -c 'exit 7'` → `(7 #f)`.
- Signal death: child is `/bin/cat` with a `to-child` stdin pipe
  (blocks deterministically, no wall-clock); `uv-process-kill!` with
  `'sigterm` → `(0 sigterm)`. The by-pid variant `uv-kill!` gets its own
  run. Liveness probe `0` returns without raising while blocked (alive
  case only — never after exit, §4.5).
- Stdout capture: `sh -c 'printf …'` through a `from-child` pipe, read to
  EOF, bytes asserted (the byte-collector helpers).
- Full echo loop: write into stdin pipe → `/bin/cat` → read from stdout
  pipe → `uv-shutdown!` stdin → EOF → exit `(0 #f)` — the test-echo.sps
  mirror, and SQ3's production twin.
- Duplex: slot 0 as `(pipe p duplex)`, child `sh -c '/bin/cat >&0'`
  (reads fd 0, writes fd 0 — a socketpair end is bidirectional); parent
  writes then reads back on the same pipe. Sole coverage of `duplex` and
  of the OR'd `UV_READABLE_PIPE|UV_WRITABLE_PIPE` rows.
- Extra fd (slot 3): child `sh -c 'printf x >&3'` with slot 3 a
  `from-child` pipe; parent reads the byte — covers >3-slot stdio and
  libuv's own 0–2 padding beneath explicit higher slots.
- argv/env/cwd combined: multi-arg argv (`"$0"`/`"$1"` printf), explicit
  env (`"FOO=bar"` visible, parent env absent), cwd honored (`pwd`) — one
  spawn asserting all three; this test is the named mutation target for
  every offset row in §5.3.
- Env inheritance: parent `putenv`, options without `env`, child prints
  it.
- `inherit-fd`: child stdout inherits a temp-file fd (via Chez
  `port-file-descriptor` on a file in `tests/tmp/`); parent reads the
  file after exit.
- `inherit-stream`: loopback TCP pair (ADR-0010 machinery); child stdout
  dups onto the connected socket; parent reads from the peer. Sole
  coverage of that mode.
- `'ENOENT` from spawning a nonexistent absolute path (synchronous
  raise); nothing half-built (counters/registry unchanged) — SQ1's
  production twin.
- `'EPERM` from `uid` as non-root — the negative setuid test lives here,
  in the *normal* suite.
- Detached: spawn `detached` + immediate `uv-close!`; loop drains without
  the child; counters balance. Nothing else asserted (never reaped).
- Lifecycle: close-after-exit (from within `on-exit`); spawn-then-never-
  close swept by `uv-loop-teardown!`; `on-exit` = `#f` reaps silently and
  the handle is still closeable; a raise inside `on-exit` is stored and
  re-raised by `uv-run` (the seam contract).
- Validation walk: every reason symbol in the §4.7 table driven. Each
  raise leaves registry and counters untouched; the *ordering* property
  (validate before the first allocation) is enforced by the memory lane —
  a mis-ordered implementation leaks the handle or options block on the
  raise path and fails valgrind, the same observable ADR-0009 relies on.

### 9.3 test-pipe.sps / test-stream.sps

- `make-uv-pipe` → close, counters balance; teardown sweep covers an
  unclosed pipe.
- Stream verbs on an unconnected pipe: the pinned errno behavior (§4.6).
- `'pipe-already-used` on second spawn naming the same pipe.
- Stream-verb gating: each verb accepts tcp and pipe, refuses timer /
  process / closed handles with the right conditions — the
  `require-open-stream` matrix. (The refuses-process row joins in Stage
  5, once `uv-spawn!` exists to construct one — §11.)
- tcp regression: the moved verbs still pass test-tcp.sps/test-echo.sps
  untouched (their import path is unchanged via re-export).

### 9.4 The root lane

- `tests/test-process-setuid.sps` is **excluded from the default suite**:
  `TESTS := $(filter-out tests/test-process-setuid.sps, $(wildcard
  tests/test-*.sps))` (Makefile:90) — which also keeps it out of
  `MEMORY_TESTS`.
- New target `make test-root`: refuses with exit 1 and a "run via `sudo
  make test-root`" message when `geteuid` ≠ 0; otherwise runs exactly
  this suite.
- The suite spawns `/usr/bin/id -u` (and `-g`) with `uid`/`gid` set to an
  unprivileged target looked up at runtime (`id -u nobody` — never a
  transcribed number), captures stdout over a pipe, asserts the child ran
  as that identity.
- CI: both existing jobs (`linux`, `macos` — ci.yml) gain a
  `sudo make test-root` step; runners have passwordless sudo. The lane is
  not under valgrind/ASan.
- ADR-0016 records the policy: privileged-but-deterministic behavior is
  testable via an opt-in root lane and therefore bindable — refining the
  v0.2 "untestable ⇒ unbound" rule, which remains in force for
  host-config-dependent behavior (AI_ADDRCONFIG stays unbound).

### 9.5 Memory lane

`make test-memory` picks up the new suites automatically. Known-good
noise: the unjoined-threadpool still-reachable note applies unchanged;
child processes themselves are invisible to the parent's valgrind. The
options-block counter pair gives the leak-shaped mutation target.

---

## 10. Stage 0 spike (`spike/process/`, findings in `spike/process/FINDINGS.md`)

Spike-first, both platforms, Linux via the `spike/**`-triggered CI branch
(pinned-Chez cache reuse; branch deleted after harvesting). Questions:

- **SQ1 — spawn failure cleanup.** Drive `'ENOENT` spawns under valgrind
  + debug counters with both cleanup strategies (close-through-protocol
  vs direct `foreign-free`); also assert `(pipe …)`-spec pipes remain
  consistently unconnected and closeable after a failed spawn. Evidence
  decides ADR-0015's failure path.
  **Answered:** there are two failure classes with opposite correct
  cleanups (the single-strategy premise was wrong), and the
  unconnected-pipes assumption was refuted — a failed spawn connects them.
  §5.6 above is rewritten to the measured result; ADR-0015 records it.
- **SQ2 — SIGCHLD coexistence (Linux).** In one process, interleave libuv
  spawns with Chez's own subprocess machinery (`open-process-ports`,
  `system`): assert libuv's `exit_cb` still fires and Chez still gets its
  statuses, in both orderings, repeatedly. macOS's kqueue path is
  structurally unaffected — one smoke run anyway. If they conflict, the
  finding becomes a documented mutual-exclusion rule in the README (the
  binding cannot fix libuv's V6 constraint, only surface it honestly).
- **SQ3 — pipe stdio under GC pressure.** The echo loop
  (stdin pipe → `cat` → stdout pipe) for 10k round-trips with `(collect)`
  in every callback; record observed EOF/exit orderings (expect both);
  assert no delivery is lost and counters balance. Justifies the
  wait-both-independently test discipline with measured evidence.

Spike code is throwaway; FINDINGS.md is the deliverable, cited by
ADR-0014/0015/0016 the way `spike/dns/FINDINGS.md` is cited today.

---

## 11. Milestone sequence

Stages follow the twice-proven process (per-stage subagent implementation,
TDD, per-stage review + mutation log, final whole-branch review, squash +
tag). Indicative cut — the implementation plan is authority:

1. **Stage 0** — spike (§10); write/accept ADR-0014/0015/0016, amend
   ADR-0008.
2. **Stage 1** — shim + constants rows (§5.3), required-names walk,
   mutation tests.
3. **Stage 2** — native.sls: `exit` and `walk` trampolines, twelve total
   (frozen literals widened watched-to-fail first), new foreign-procedures.
4. **Stage 3** — handles.sls: `uv-stream-record` hierarchy, pipe/process
   records, kind/counter/close-dispatcher widening; tcp regression green.
5. **Stage 4** — `(libuv stream)` extraction + `(libuv pipe)` +
   `uv-pipe?`/`uv-process?` in `(libuv handle)`; test-stream.sps,
   test-pipe.sps.
6. **Stage 5** — `(libuv process)`: spawn flow, exit dispatcher, kill
   family; test-process.sps.
7. **Stage 6** — root lane (Makefile + suite + CI steps), facade blocks,
   README/CHANGELOG, final review; squash-merge, tag `v0.3.0`, closing
   ritual per AGENTS.md.

Deferred, recorded for future milestones: `uv_signal_t` (explicitly
requested as a next-milestone note), pipe `bind`/`connect`/`listen`,
`ipc=1` fd-passing, `uv_ref`/`uv_unref`, `uv_disable_stdio_inheritance`.
