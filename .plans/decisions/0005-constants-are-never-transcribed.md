# ADR-0005: Constants are never transcribed — looked up by name from the shim

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0002](0002-direct-ffi-with-constants-only-shim.md)

## Context

The obvious way to give Scheme code access to a C constant like `AF_INET` or
a `uv_buf_t` field offset is to read its value once and write it into a
`(define AF_INET 2)` somewhere in the Scheme source. This is fast to write
and reads as an ordinary definition — and it is a silent, version- and
platform-dependent trap: the value can differ across platforms, across libuv
versions, or simply be mistyped, and none of those failures is visible until
the binding misbehaves at runtime, likely against exactly the socket family
or buffer layout the value was supposed to encode correctly.

libuv exposes roughly 70 errno-style constants alone
(`UV_ERRNO_MAP`), which rules out one `foreign-procedure` per constant as
unwieldy, and rules out a positional array indexed by an assumed order as no
better than transcription — the array's index contract is itself a value
that would have to be kept in sync by hand between the C shim and the Scheme
consumer, which is the same failure mode wearing a different shape.

## Decision

The shim exports exactly one lookup function for scalar constants,
`int chez_uv_constant(const char *name, long *out)`, backed by a name-keyed
table built from real libuv headers: `UV_RUN_*` mode constants, `UV_EOF`,
`AF_INET`/`AF_UNSPEC`, `sizeof` for every struct this binding allocates
(loop, tcp, timer, write, connect, buf, `sockaddr_in`,
`sockaddr_storage`), and `offsetof` for `uv_buf_t`'s `base`/`len` fields and
`sockaddr_in`'s `sin_port`/`sin_family` fields. A name absent from the table
is not a zero, a null, or a default — it is a structured init-time failure,
`&uv-constant-unavailable` carrying the missing name, raised by
`ensure-native-loaded!` before any handle can be created.

Errno *names* are enumerated separately, via an X-macro expansion over
libuv's own `UV_ERRNO_MAP`, so the name list itself tracks the pinned libuv
header automatically rather than being copied out by hand
(`chez_uv_errno_count`/`name`/`value`).

Because failure is structured and specific — a named condition, not a
default value — this policy is directly mutation-testable: deleting or
corrupting a single table entry must make one specific, predictable test fail
by name, not merely "some test somewhere."

## Consequences

- The shim's constants-only shape ([ADR-0002](0002-direct-ffi-with-constants-only-shim.md))
  is preserved; adding a constant this binding needs later means adding one
  table entry, not a new exported function.
- `test-native`'s bogus-name case and its full errno round-trip are the
  concrete tests this policy's mutation-testability claim rests on — a
  passing suite with the table entry deleted is a failed ADR, not a passed
  one.
- The same `sizeof`/`offsetof` mechanism this ADR mandates is what keeps
  struct layouts Windows-portable ahead of
  [ADR-0004](0004-windows-deferred-design-clean.md); the two decisions
  reinforce each other rather than being independent.
- Every constant lookup costs one FFI round trip at init time rather than
  zero at compile time — accepted, since it happens once, behind
  `ensure-native-loaded!`, not on any hot path.

> **Extended 2026-09-19 (issue #21).** The same table also carries
> *version-gated* constants that a supported libuv may legitimately lack.
> `UV_TCP_REUSEPORT` (TCP `SO_REUSEPORT`, libuv ≥ 1.49.0) is the first: its
> shim-table entry is guarded by `#if UV_VERSION_HEX >= 0x013100` — it is an
> enum value, invisible to `#ifdef`, so a version guard is the only compile-time
> gate — and, crucially, it is looked up through the **lazy** `constant-ref`
> path (`uv-tcp-reuseport`), NOT added to `snapshot-names`. A snapshot entry
> would fail the whole `constants-init!` on an older libuv, breaking a binding
> that otherwise works; the lazy path instead raises `&uv-constant-unavailable`
> naming `UV_TCP_REUSEPORT` only for a caller who actually asks for the flag.
> This is the same structured-failure discipline as above, applied at the point
> of use rather than at init — the pattern for any future optional/gated
> constant.
