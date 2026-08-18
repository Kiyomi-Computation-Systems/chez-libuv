# ADR-0001: Acquire libuv via pkg-config with a pinned vendored submodule fallback, shared-only

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md)

## Context

libuv is not guaranteed present on a consumer's machine. The development
machine has Homebrew's libuv 1.52.1 with a working `libuv.pc`, but CI and
downstream consumers cannot assume `pkg-config` finds anything, or that what
it finds is a version worth testing against.

Three shapes were available: system-only via `pkg-config`, always-vendored
from a pinned submodule, or a hybrid of the two. System-only is light but
leaves version drift between developer machines, CI, and end users
unconstrained. Vendored-only guarantees a known version everywhere but forces
every consumer to compile libuv, even when a perfectly good system copy
exists.

A further constraint narrows the choice on the *linking* axis, and it is
known up front rather than discovered later: this binding calls `uv_*`
functions directly via `foreign-procedure`
([ADR-0002](0002-direct-ffi-with-constants-only-shim.md)), which requires
those symbols to be visible in a real shared object at runtime. The sibling
project this harness is adapted from, `chez-cmark-gfm`, specified static
linking for its vendored path and only discovered empirically — after
shipping — that a statically-linked shim hides every symbol from the library
it links, because the static archive is built with hidden visibility. That
project's traversal-in-Scheme decision was load-bearing, so its linking
strategy had to give way afterward, as an amendment. This binding starts from
that lesson already applied.

## Decision

Normal builds discover a system libuv through `pkg-config`
(`HAVE_PKG := pkg-config --exists libuv`). A pinned git submodule at
`vendor/libuv`, tracking v1.52.1, is the fallback, built explicitly by
`make vendor` and automatically whenever `pkg-config` finds nothing.

**Both paths link shared, unconditionally — there is no static option on
either path.** The vendored build is configured
`-DLIBUV_BUILD_SHARED=ON`, its artifacts land at the build root
(`build/vendor/`, not `src/`), and the shim links against them with an
explicit absolute `-Wl,-rpath`, never a system path search. This is not an
optimization choice deferred for later measurement; it is required the first
time a `uv_*` symbol is bound, because a static archive would hide it.

CI exercises both acquisition paths on every run.

## Consequences

- Two build paths to maintain and test, but structurally identical: both
  resolve libuv symbols dynamically at runtime, so there is one Scheme-side
  code path rather than two.
- The vendored build must be present and loadable at runtime, not merely at
  link time — the absolute rpath makes this explicit rather than relying on
  `LD_LIBRARY_PATH` or a working-directory search.
- CI pins `vendor/libuv` at v1.52.1 so the vendored path is testing a known
  version, while the pkg-config path exercises whatever the platform ships
  (apt's 1.48, brew's 1.52.1 at time of writing) — both must fall inside the
  version range validated at init (see the design spec's native.sls rules).
- Because `pkg-config` is impractical on Windows, this ADR's fallback path is
  also the one Windows would rely on primarily whenever
  [ADR-0004](0004-windows-deferred-design-clean.md) lands — a fact that
  informs how much CMake configuration is worth getting right now.
