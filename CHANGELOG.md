# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org).

## Unreleased

- **Added** `&uv-libuv-unavailable`, raised when libuv's own shared object
  cannot be resolved or loaded — a subtype of `&uv-shim-unavailable`, so
  guards on the parent keep matching (previously both failures were raised
  as the parent, with the `path` field as the only discriminant).
  Re-exported from `(libuv)`; sharper predicate `uv-libuv-unavailable?`.

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
