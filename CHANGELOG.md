# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org).

## 0.4.0 — 2026-08-XX

### Added

- `(libuv signal)`: `make-uv-signal`, `uv-signal-start!`,
  `uv-signal-start-oneshot!`, `uv-signal-stop!`; kind predicate
  `uv-signal?`; `uv-os-getpid` (exported from `(libuv process)` beside
  `uv-process-pid`). The callback receives the watched signal as a symbol.
- The thirteenth locked trampoline (`signal`) — ADR-0008's third
  amendment, which states the one-per-callback-TYPE rule in its own terms
  (`uv_signal_cb` shares `connection`'s arity and still gets its own slot).

### Semantics

- Watchable set: the closed nine-symbol vocabulary minus
  `sigkill`/`sigstop` (`'signal-unwatchable`); exact `0` stays
  sending-only (`'signal-unknown`); `sigchld` remains inexpressible (libuv
  owns SIGCHLD for child reaping — vendor fact V6).
- **Mode is fixed per handle** (`'signal-mode-fixed`): the first
  successful start verb pins continuous/oneshot for the handle's life;
  mode change is close-and-recreate (the vendored `UV_SIGNAL_ONE_SHOT`
  ratchet, measured — spike/signal/FINDINGS.md EV-8).
- DELIVERY ≠ CLOSE: stop and oneshot auto-disarm never close; the caller
  always `uv-close!`s (close implicitly stops an armed watcher, EV-10).
- Rearming a oneshot watcher from inside its own callback does not take
  effect (the vendor auto-stop runs after the callback returns, EV-9).

### Notes

- Measured caveat (SQ-S1, both platforms): watching `sigint` takes SIGINT
  from the Chez runtime, and `uv-signal-stop!` leaves `SIG_DFL` — neither
  `keyboard-interrupt-handler` nor `register-signal-handler` handling is
  restored. libuv's behavior, surfaced rather than fixed (README).
- The signal vocabulary validators lifted from `process.sls` to
  `(libuv private native)` on their second user — the rule recorded at
  their v0.3 introduction. `(libuv process)`'s surface is unchanged
  (plus `uv-os-getpid`).

## 0.3.0 — 2026-08-21

Child processes: `uv_spawn` with the full stdio vocabulary, as `(libuv
process)`, plus a deliberately minimal `(libuv pipe)` (`uv_pipe_init` only,
no bind/connect/listen, no `ipc=1`) that exists so pipes can be handed to a
spawn as a child's stdio end. Getting there required the one honest
refactor both needed: the stream verbs (`uv-write!`, `uv-shutdown!`,
`uv-read-start!`, `uv-read-stop!`) move out of `(libuv tcp)` into a new
`(libuv stream)`, gated on stream-*kind* rather than tcp-kind — `(libuv
tcp)` re-exports all four, so no importer has to change. This is the
binding's first subprocess machinery and its first interaction with the
host's child-reaping signals; both are governed by three new decision
records (ADRs 0014–0016 under `.plans/decisions/`, gated on the Stage 0
spike under `spike/process/`), and the full design is
`.plans/2026-08-21-chez-libuv-v0.3-process-design.md`.

### Added

- `(libuv process)`: `uv-spawn!` (`loop file args [options] on-exit` →
  process handle, child already running), with an options alist covering
  `env` (a list of `"K=V"` strings, libuv's own format — no alist
  encoding invented), `cwd`, `stdio`, `detached`, and `uid`/`gid` (setting
  either implies the matching `UV_PROCESS_SETUID`/`SETGID` flag — the
  binding closes the "field set, flag clear" footgun libuv leaves open).
  The `stdio` vocabulary covers `ignore`, `(inherit-fd . n)`,
  `(inherit-stream . h)`, and `(pipe p dir)` with `dir` one of
  `to-child`/`from-child`/`duplex` — named from the parent's perspective,
  deliberately not libuv's child-perspective `READABLE`/`WRITABLE` flags.
  `uv-process-kill!`/`uv-kill!` take a signal from a closed symbol set
  (`sigterm sigkill sigint sighup sigquit sigusr1 sigusr2 sigcont
  sigstop`) or the exact integer `0` as the POSIX liveness probe;
  `uv-process-pid` and `uv-process?` round out the surface. All of it
  re-exported from `(libuv)`.
- `(libuv pipe)`: `make-uv-pipe` (`uv_pipe_init`, ipc always 0) and
  `uv-pipe?`.
- `(libuv stream)`: the four verbs extracted from `(libuv tcp)`, now
  accepting any open tcp or pipe handle.
- The exit callback contract: `on-exit` receives `(exit-status
  term-signal)` as results, never a condition — libuv's `exit_cb` has no
  error argument. A child killed by signal delivers `(0 sigterm)`, not
  `(-1 …)` — `exit-status` is `WEXITSTATUS` on a normal exit and *zero* on
  a signal death; `term-signal` is `#f` on a normal exit, otherwise the
  signal symbol or the raw integer for a signal outside the bound set.
- The root lane: `tests/test-process-setuid.sps`, excluded from `make
  test`/`make test-memory` and run separately by `sudo make test-root`
  (refuses with a clear message under a non-root euid), to exercise
  `uid`/`gid` as the privileged behaviour they are. Both CI jobs (`linux`,
  `macos`) gained a `sudo make test-root` step.

### Changed

- Callback dispatch grows from ten to twelve static locked trampolines
  (`exit`, `walk`). ADR-0008 is amended a second time; the "one locked
  trampoline per callback type, constant per process" invariant now
  covers twelve.
- `uv-loop-teardown!`'s close sweep now also covers pipe and process
  handles (`handle-kinds` widens to include them); an un-closed process
  handle is caught exactly like an un-closed tcp handle. Exit and close
  remain two distinct events (unchanged from libuv, newly documented
  here): `on-exit` firing stops the handle but does not close it — the
  caller still calls `uv-close!`, typically from inside `on-exit`.
- The spawn-failure cleanup path is class-dependent, decided at runtime by
  asking the loop (`uv_walk`, the twelfth trampoline) rather than by
  errno (ADR-0015): an exec failure leaves the handle still linked into
  the loop's handle queue and needs `uv-close!`-through-protocol; a
  stdio-setup failure has already been unlinked by libuv and needs a
  direct free. Getting the wrong arm either corrupts the loop's handle
  queue or leaves it permanently `EBUSY`. A pipe named in any of the spawn's stdio specs is marked *connected* by a failed spawn too — libuv opens
  the parent end before it can know whether the exec will succeed — so
  the caller must still close it; naming it again raises
  `'pipe-already-used`. **Version-dependent finding, not a binding bug:**
  which failure class a given trigger lands in also depends on the
  libuv underneath — upstream commit `3e9ae1bc` (libuv 1.52.0) is what
  first unlinks a stdio-setup failure's handle; on an older libuv (found
  via Linux CI's apt `libuv1-dev` 1.48.0) the same trigger lands in the
  exec class instead, and the runtime discriminator handles both
  correctly. ADR-0015 and the design spec's §5.6 carry the full account.

### Notes

- **SQ2 spike finding: no conflict with Chez's own subprocess APIs.**
  Interleaving libuv spawns with Chez's `system`/`open-process-ports`
  across four orderings delivered 110/110 libuv `exit_cb`s intact, with
  every Chez call also returning its own correct result — measured on
  Linux's SIGCHLD-based child-reaping path, the one path where a stolen
  wait can silently drop a callback (`spike/process/FINDINGS.md` SQ2). No
  mutual-exclusion warning was needed as a result.
- No `uv_signal_t`: v0.3 binds only the signal-*sending* side
  (`uv-process-kill!`/`uv-kill!`). Handling signals in the loop is a
  recorded future-milestone candidate.
- Run 32544754290, which executed the root lane as root on both
  platforms, also delivered the first Linux valgrind verdict over the
  process surface (the root suite itself is excluded from the memory
  gate): zero errors, zero definitely/indirectly lost bytes across all
  sixteen valgrinded processes.
- The libuv version floor is unchanged: 1.44.0 or later in the 1.x
  series.

## 0.2.0 — 2026-08-21

DNS: libuv's complete resolver surface — `uv_getaddrinfo`, `uv_getnameinfo`,
`uv_cancel` — as `(libuv dns)`, in the established house style. What
`getaddrinfo(3)` and `getnameinfo(3)` do on the host is what this binding
does: no c-ares, no record types (MX/TXT/SRV), no caching, async only. This
is the binding's first use of libuv's worker threads and its first
handle-less, loop-scoped request kind; both firsts are governed by new
decision records (ADRs 0011–0013 under `.plans/decisions/`, gated on the
Stage 0 spike under `spike/dns/`), and the full design is
`.plans/2026-08-21-chez-libuv-v0.2-dns-design.md`.

### Added

- `(libuv dns)`: `uv-getaddrinfo!` (node/service strings or `#f`, hints as
  an alist over closed symbol sets — `family`/`socktype`/`protocol`/`flags`,
  no raw ints), `uv-getnameinfo!` (the TCP address vocabulary on the way
  in), `uv-cancel!` (`#t` only if the work was still queued; the callback
  still fires, with `'EAI_CANCELED`), and `uv-dns-request?`. Results are
  `uv-addrinfo` records — pure copied Scheme values with a public
  constructor and six accessors; nothing here takes or returns a pointer.
  All of it re-exported from `(libuv)`.
- Resolver failures surface as ordinary `&uv-errno-error` conditions whose
  `errno` is the `EAI_*` symbol (`'EAI_NONAME`, `'EAI_AGAIN`,
  `'EAI_CANCELED`, …) — no DNS-specific condition types, and cancellation
  is `'EAI_CANCELED` in exactly one spelling, because libuv itself rewrites
  `UV_ECANCELED` before the callback runs.
- `&uv-libuv-unavailable`, raised when libuv's own shared object
  cannot be resolved or loaded — a subtype of `&uv-shim-unavailable`, so
  guards on the parent keep matching (previously both failures were raised
  as the parent, with the `path` field as the only discriminant).
  Re-exported from `(libuv)`; sharper predicate `uv-libuv-unavailable?`.

### Changed

- Callback dispatch grows from eight to ten static locked trampolines.
  ADR-0008 is amended in place: the invariant is "one locked trampoline per
  callback *type*, constant per process", which the literal eight was an
  instance of.
- `uv-loop-teardown!` is now cancel-then-drain: it best-effort-cancels the
  loop's in-flight DNS requests before its close sweep, and every in-flight
  `on-complete` runs before teardown returns — with `'EAI_CANCELED` if the
  cancel won, with the real result if the work was already running. A
  running `getaddrinfo(3)` is uninterruptible, so that drain iteration
  waits it out, up to the OS resolver's own timeout.
- **Behaviour change:** `uv-loop-close!` now re-raises a stored pending
  callback error after a *successful* close, composed as
  `&uv-callback-error` with the original condition — the exact composition
  `uv-run`'s exit path uses. Previously a caller who skipped the next
  `uv-run` and went straight to close lost the error silently; code that
  relied on that discard will now see the raise (the loop is closed when it
  escapes). A close refused with `'EBUSY` is unchanged: nothing is
  delivered, and the error stays pending for a later `uv-run` or close.

### Fixed

- `copy-in!`/`copy-out` (private FFI helpers): a non-numeric span
  argument now raises the structured `&uv-invalid-argument` instead of a
  bare Chez assertion escaping from `exact?`.

### Notes

- IPv6 scope IDs are dropped (ADR-0012): a link-local result renders as
  `"fe80::1"` with its zone silently absent. The fix path (a shim offset
  for `sin6_scope_id` plus `uv_if_indextoname`) is recorded in the ADR.
- Threadpool workers run pure C — no Scheme ever runs off the loop thread —
  and completions are delivered on the loop thread like every other
  callback. `UV_THREADPOOL_SIZE` is read by libuv once, at first use.
- The libuv version floor is unchanged: 1.44.0 or later in the 1.x series.

## 0.1.0 — 2026-08-18

The first release: a legible, low-level mirror of libuv's event loop, TCP
sockets and timers as an R6RS library for Chez Scheme. Transport only — it
parses nothing and understands no protocol above raw bytes, so the HTTP layer
above it implements its own connection-state and backpressure policy directly
against these primitives.

Four decisions shape everything else, and each has its own record under
`.plans/decisions/`:

- **Direct FFI, constants-only shim** (ADR-0002). `uv_*` entry points are
  bound with `foreign-procedure` straight from Chez; the C shim exports the
  constants, struct sizes and offsets this binding must not transcribe, plus
  the debug counters. No hand-written C wrapper stands between a caller and
  libuv.
- **Copy at the boundary** (ADR-0009). Every buffer crossing the FFI is
  copied, in both directions. Nothing libuv holds points into the Scheme
  heap, so there is no pinning, no `lock-object` per write, and no window in
  which a moving collector can invalidate an in-flight operation. Zero-copy
  is deferred, not foreclosed: `on-data` is handed a *span*, so a sub-range
  variant needs no new call shape.
- **Errors are symbols** (ADR-0006). A negative libuv return code becomes
  `&uv-errno-error` carrying the portable symbol `uv_err_name_r` gives
  (`'ECONNRESET`), which is what callers branch on. The raw platform integer
  is preserved beside it for logs and is never the discriminant.
- **No guardians** (ADR-0007). `uv_close` is always explicit. A handle nobody
  closes leaks deterministically and visibly in the debug counters, rather
  than being swept up at some later GC on some other thread — a leak a test
  can see beats a close that happens eventually.

### Added

- `(libuv loop)`: `make-uv-loop`, `uv-run` (`'default` / `'once` /
  `'nowait`), `uv-stop!`, `uv-loop-alive?`, `uv-now`, `uv-loop-live-handles`,
  `uv-loop-deferred-errors`, `uv-loop-close!`, `uv-loop-teardown!`, and
  `call-with-uv-loop`. `uv-run` answers a **boolean**, not libuv's int: `0`
  is true in Scheme, so handing the raw value back would make `(when (uv-run
  l) …)` fire on exactly the case it means to skip.
- `(libuv handle)`: `uv-handle-state` (`'open` / `'closing` / `'closed`), the
  two never-raising state predicates, `uv-handle-loop`, and `uv-close!` —
  idempotent, asynchronous, and the only path by which a handle's memory is
  ever released. There is deliberately no `uv-handle-closed?` predicate; that
  name belongs to the condition.
- `(libuv tcp)`: `make-uv-tcp`, `uv-tcp-bind!`, `uv-tcp-getsockname-port`,
  `uv-listen!`, `uv-accept!`, `uv-tcp-connect!`, `uv-write!` (whole
  bytevector or span), `uv-shutdown!`, `uv-read-start!` / `uv-read-stop!`,
  and `uv-tcp-nodelay!`. Reads deliver through three **required** callbacks —
  `on-data (bv start end)`, `on-eof ()`, `on-error (condition)` — because a
  stream whose end and whose failure both go unnoticed is not a
  simplification. EOF is not an error and is never wrapped in a condition; a
  read error does not close the handle.
- `(libuv timer)`: `make-uv-timer`, `uv-timer-start!`, `uv-timer-stop!`,
  `uv-timer-again!`, `uv-timer-repeat`, `uv-timer-set-repeat!`.
- `(libuv)`, the facade: every name above, re-exported by hand rather than
  wholesale, plus `uv-version` and `uv-version-compatible?`. A facade that
  re-exported whatever its imports happened to have would leak a private
  binding the day someone added one.
- The condition hierarchy, rooted at `&uv-error`: `&uv-errno-error`,
  `&uv-handle-closed`, `&uv-shim-unavailable`, `&uv-version-incompatible`,
  `&uv-constant-unavailable`, `&uv-invalid-argument`, `&uv-callback-error`.
  Predicates, accessors *and* constructors are public — a caller's own
  `on-error` may want to build or re-raise one.
- Callback-boundary discipline (design spec §8): a raise inside a callback
  never crosses into C. The first one of a run is stored, the loop is
  stopped, and it is re-raised from `uv-run` composed with
  `&uv-callback-error`, so a `guard` written against the original condition
  type still matches; later raises are readable through
  `uv-loop-deferred-errors`. Dispatch goes through eight static, `lock-object`'d
  trampolines and a handle/request registry (ADR-0008) — never one locked
  callable per handle.
- The build harness: hybrid native acquisition (`pkg-config` with a pinned
  vendored `libuv` submodule fallback, ADR-0001), the constants-only C shim,
  a generated `config.sls` carrying absolute paths so the loader never
  searches, the validated-never-searched `CHEZ_LIBUV_SHIM` override, Akku
  packaging, and CI over macOS and Linux on both acquisition paths.
- `make prod` / `make check-prod`: a validated `FLAVOR` variable, a
  `build/.flavor-*` stamp recording which flavor the artifact was linked as,
  and `relink-guard` — the first prerequisite of `build`, which **deletes**
  an artifact whose recorded provenance no longer matches what was asked for.
  The deletion is what forces the relink, not the stamp: make 3.81 compares
  mtimes at one-second granularity and treats equal as up to date, so a stamp
  recreated in the same second as the previous link forces nothing, while a
  missing artifact is rebuilt whatever the clock said. The guard covers a
  change of acquisition path too. Alongside them, a behavioural probe that
  fails unless the built shim really is the counters-free release artifact.
  `prod` and `build` write the same path, so `make prod && make test &&
  package` used to package a dev relink.
- `tests/test-echo.sps`, the capstone: an echo server and eight concurrent
  in-process clients on one loop, 512 KiB of loopback traffic (256 KiB each
  way) compared byte for byte, with a read-stop/read-start applied and
  released from inside delivery callbacks, ending in seventeen closed
  handles and every counter at
  zero. It imports the facade and nothing else from this project, which is
  how the public surface is checked for sufficiency.
- Documentation: the design spec and ADRs 0001–0010 under `.plans/`, the
  Stage 0 spike and its `spike/FINDINGS.md` (which is what flipped ADR-0002
  and corrected ADR-0008's rationale), and a per-stage mutation log recording
  every assertion watched to fail — including the ones nothing could catch,
  and why.

### Known limitations

- No DNS, process, filesystem, UDP, pipe or signal bindings. v0.1 is the
  loop, TCP and timers.
- **Windows is deferred, not designed out** (ADR-0004). The one libuv struct
  this binding constructs has a different field order there, and its layout
  is validated at initialisation, so an unverified platform fails closed
  rather than writing a length into a pointer field.
- **Leak claims come from Linux only** (ADR-0003). LeakSanitizer does not
  exist on macOS/ARM64, so the macOS `make test-memory` leg reports
  use-after-free and double-free and says nothing about leaks.
