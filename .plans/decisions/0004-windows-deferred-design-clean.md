# ADR-0004: Defer Windows CI while keeping the design Windows-clean

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0005](0005-constants-are-never-transcribed.md)

## Context

`AGENTS.md` calls for portability across macOS, Linux, and Windows, and
across amd64 and arm64. v0.1's verified toolchain and CI, however, cover only
macOS and Linux — a full Windows CI leg would require an MSVC or MSYS2 build
of the shim and would fork the memory-verification story
([ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md)), since Valgrind
does not exist on Windows and a green MSYS2/mingw leg would misrepresent how
an MSVC-built Chez actually consumes the library. Neither is justified before
v0.1's actual risk — the callback architecture of
[ADR-0002](0002-direct-ffi-with-constants-only-shim.md) — is retired.

Deferring Windows entirely, the way `chez-cmark-gfm` did, is not available
without cost here, though, because two of libuv's own data layouts are
platform-dependent in ways that leak into this binding's design *now*,
whether or not Windows CI ever runs:

- `uv_buf_t` is `{char* base; size_t len}` on Unix, but the field order flips
  on Windows.
- `sockaddr_in` and related structures have platform-dependent layout
  (notably BSD's `sin_len` byte), which is exactly why this binding reads
  such offsets from the shim's `offsetof` table rather than declaring a
  fixed `ftype` for them.

A subtler trap: the shim's constant-lookup function,
`chez_uv_constant(const char *name, long *out)`, uses a C `long` out-param.
`long` is 64-bit on Linux/macOS (LP64) but only 32-bit on Windows (LLP64).
Every value the lookup table currently returns — version hex, `sizeof`
results, small `offsetof` values, socket-family constants — fits within 32
bits, so this is latent rather than active. It would stop being latent the
moment a future constant needed more than 32 bits on a build that also
targets Windows.

## Decision

v0.1 verifies Linux and macOS only in CI. The design stays strictly portable
in the meantime: no POSIX-only APIs in `libuv-shim.c`/`.h`, and every struct
layout this binding depends on is obtained from the shim's `sizeof`/`offsetof`
getters ([ADR-0005](0005-constants-are-never-transcribed.md)) rather than
hardcoded — a policy that exists independently for the never-transcribe
reason, and happens to be exactly what Windows-readiness also requires.

The LLP64 `long` caveat on `chez_uv_constant`'s out-param is recorded here as
a known, currently-inert limitation: it must be revisited — most likely by
widening the out-param type — before any constant needing more than 32 bits
is added to a Windows-targeting build.

## Consequences

- Resolves the tension between `AGENTS.md`'s full portability requirement and
  v0.1's actual verified scope: Windows is a documented deferral, not an
  oversight, and the supported-platform matrix must say so explicitly.
- v0.1 effort stays on the project's real risk — callback correctness under
  GC — rather than platform breadth that nothing yet depends on.
- The `offsetof`/`sizeof`-getter policy means adding Windows later is
  primarily CI and acquisition-path work
  ([ADR-0001](0001-hybrid-native-dependency-acquisition.md)), not a
  layout redesign.
- The LLP64 `long` caveat is a standing item any future Windows-enabling
  change must check against before it can be closed.
