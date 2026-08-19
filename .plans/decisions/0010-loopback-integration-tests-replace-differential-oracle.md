# ADR-0010: Loopback integration tests replace a differential oracle

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md)

## Context

`chez-cmark-gfm`'s correctness oracle is differential testing: parse the same
input with the pinned `cmark-gfm` CLI and with the binding, and diff the
output. That works because cmark-gfm is a document-transforming tool with a
meaningful reference CLI to diff against.

libuv has no equivalent. It is an event-loop and asynchronous I/O runtime,
not a transforming tool — there is no CLI whose output this binding's TCP or
timer behavior could be diffed against. A different validation strategy is
required, not an adaptation of the cmark-gfm approach.

## Decision

Correctness is anchored to two things instead of a differential oracle:

1. **Kernel-level TCP semantics**, exercised by looping the binding back on
   itself: bind `127.0.0.1:0`, read the real ephemeral port back via
   `uv_tcp_getsockname`, and connect to it from the same loop, in the same
   process. The wire behavior under test is the real OS network stack, not a
   mock or a fake — this is also how libuv's own test suite validates itself,
   so the approach carries precedent from the library being bound, not just
   from this project's own judgment.
2. **libuv's own documented callback contract**, encoded directly as test
   assertions — ordering guarantees such as "every request callback fires
   before `close_cb`, and `close_cb` fires last" (design spec §5), `nread`
   semantics (design spec §6), and the rest — rather than diffed against a
   second implementation.

The capstone, `test-echo`, runs 8 concurrent in-process loopback clients,
each sending a seeded-random 32 KiB payload across 3 chunks, compared
byte-for-byte against what was sent, with graceful teardown and all debug
counters back at zero — one instrumented process, so Valgrind
([ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md)) observes the
entire exchange.

## Consequences

- No external process or subprocess dependency for correctness; subprocess
  clients are rejected by design (design spec §11) — determinism and freedom
  from port collisions both depend on staying in one process.
- Tests stay deterministic despite exercising genuine asynchronous I/O,
  because `run-until` steps `uv-run 'once` up to a bounded iteration count
  rather than depending on wall-clock timing anywhere.
- There is no independent "known-good" implementation to catch a bug
  replicated identically in both the binding and its own tests — a risk a
  differential oracle would otherwise cover. Code review and the mutation-log
  discipline (`AGENTS.md`) are what fill that specific gap here instead.
- Because the oracle is the kernel and libuv's documented contract rather
  than a second program, adding a new test never requires vendoring or
  invoking anything beyond what this project already builds.
