# ADR-0003: Linux Valgrind is the sole memory-leak gate; macOS ASan is supplementary

- **Status:** Proposed — to be accepted with Stage 0 spike evidence
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0002](0002-direct-ffi-with-constants-only-shim.md)

## Context

The lifecycle logic this binding's memory safety depends on lives in Scheme
(handle registration, close-time freeing, the read/write allocation paths of
[ADR-0009](0009-copy-at-the-boundary.md)), so it cannot be exercised by a
pure-C test harness — it has to run in-process, with Chez actually running.

Chez is not built with sanitizers, so ASan requires preloading its runtime
(`DYLD_INSERT_LIBRARIES` on macOS) into a process that was never instrumented
for it. Valgrind needs no such instrumentation of anything it runs.

The decisive constraint, carried over from the same finding in
`chez-cmark-gfm`'s own memory-verification ADR: **LeakSanitizer is not
supported on macOS/ARM64**, the development machine's platform. ASan there
still catches use-after-free and buffer overflows, but it cannot find leaks.
Separately, neither Valgrind nor ASan attributes a leak to a specific test —
both report at process granularity, and this binding's tests need per-test
granularity to be useful (a leaking `test-tcp` case should not force
re-reading all of `test-lifecycle` to find it).

## Decision

Linux CI is the authoritative gate for every memory-leak claim, running
Valgrind against the built suite (`make test-memory`). macOS runs ASan via
`DYLD_INSERT_LIBRARIES` on a supplementary basis — useful for use-after-free
and overflow detection, but never cited as leak evidence, documented as such
directly in the Makefile and CI configuration rather than left implicit.

Independently, the shim maintains debug allocation counters
(`CHEZ_LIBUV_DEBUG_COUNTERS`) across six classes — `loop`, `tcp`, `timer`,
`write_req`, `connect_req`, `read_buffer` — queryable from Scheme as
`live-counts`, so any individual test can assert its own balance rather than
waiting for a process-level verdict. `UV_USE_IO_URING=0` is documented as an
escape hatch for Valgrind noise against io_uring on the pinned Linux kernel,
should it appear.

## Consequences

- A green macOS run is never sufficient evidence for a memory claim; CI
  configuration and any release notes referencing memory safety must say so
  explicitly.
- Counters give per-test granularity that neither tool provides natively,
  behave identically on both platforms, and compile to nothing under
  `make prod`.
- Counters make failure-path testing tractable: inject a failure, assert
  counters returned to baseline — the pattern `test-lifecycle` uses
  throughout.
- Valgrind remains the outer gate for what counters cannot see by
  construction: overflows, use-after-free, and any leak originating inside
  libuv itself rather than in this binding's own allocations.
