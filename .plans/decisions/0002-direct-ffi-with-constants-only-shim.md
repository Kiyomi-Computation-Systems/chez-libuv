# ADR-0002: Bind libuv directly via FFI; keep the C shim to constants only

- **Status:** Proposed — to be accepted with Stage 0 spike evidence
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0001](0001-hybrid-native-dependency-acquisition.md)

## Context

`chez-cmark-gfm`'s C shim wraps every native call it needs, because cmark-gfm
is a tree-ownership API where the interesting work — traversal, in that
project's case — was deliberately moved to the Scheme side, leaving the C
layer thin but still call-wrapping. libuv is a different shape of problem: it
is already a small, stable, intentionally-directly-callable C API (`uv_*`),
not an ownership-transfer-heavy tree.

Two architectures were considered for the callback-bearing calls this binding
needs (`uv_read_start`, `uv_write`, `uv_timer_start`, and the rest):

- **Option A — direct FFI.** `foreign-procedure` bindings straight to `uv_*`
  symbols. The C shim exports nothing that wraps a libuv call; it exists
  purely to expose values C can compute that Scheme cannot obtain any other
  way (struct sizes and offsets, the errno enumeration, debug counters).
- **Option B — C trampoline layer.** Hand-written C wrapping every `uv_*`
  call this binding needs, mirroring the shape of the cmark-gfm shim. This
  insulates the Scheme side from libuv API churn but roughly doubles the
  hand-maintained C surface and reintroduces a second boundary — the shim's
  own header — that must stay synchronized with libuv's.

Option A is materially riskier: it requires `foreign-callable` trampolines
that libuv itself invokes asynchronously, re-entering Chez from inside a
blocking `uv_run` call, with GC pressure on that path. This is exactly the
callback machinery `chez-cmark-gfm` never needed, since cmark is synchronous
end to end. Stage 0's spike exists specifically to retire this risk before
committing to it (Q1: timer callback re-entry from inside `uv_run` under GC
pressure, 10,000 iterations).

## Decision

Bind `uv_*` functions directly via `foreign-procedure`. The C shim
(`libuv-shim.c`/`.h`) exports exactly four things: the compiled version
getter, the name-keyed constant lookup function, the errno enumeration, and
debug counters — never a function that itself calls into libuv on the
binding's behalf.

On Linux this requires libuv's own shared object to be `load-shared-object`'d
by absolute path *before* the shim is loaded, because Linux's per-object
`dlopen` namespacing means the shim would not otherwise see libuv's symbols
resolved when its own `foreign-procedure` declarations are evaluated. This
load-order requirement is recorded here because it is a direct structural
consequence of choosing Option A; a C-trampoline shim (Option B) would not
have needed it, since Option B's C code links against libuv itself at build
time rather than relying on Scheme-side symbol resolution.

If Stage 0's Q1 spike shows callback re-entry under Option A is unsafe, the
recorded fallback is Option B, without changing the public Scheme API the
layers above this binding depend on.

## Consequences

- The shim stays small — four exported entry points regardless of how many
  `uv_*` functions the binding eventually calls — which keeps the
  never-transcribe-constants policy
  ([ADR-0005](0005-constants-are-never-transcribed.md)) cheap to maintain.
- The Linux load-order requirement becomes a hard invariant, enforced in
  `native.sls` and covered by `test-shim-loading`; getting it wrong fails at
  import time, not at first call.
- Direct FFI means libuv API surface changes propagate straight into Scheme
  bindings with no C-side insulation layer to absorb them — an accepted cost,
  since libuv's 1.x ABI is stable by libuv's own guarantee.
- This decision is the one most directly contingent on the Stage 0 spike;
  its status cannot move to `Accepted` before Q1's evidence is recorded.
