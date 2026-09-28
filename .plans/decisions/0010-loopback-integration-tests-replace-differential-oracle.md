# ADR-0010: Loopback integration tests replace a differential oracle

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit. Amended 2026-09-28 (issue #35): same-process speed ratios against libc gate the bulk moves — see the section at the end.
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

## Companion (2026-09-19, issue #20): threaded tests

The threading arc ([ADR-0019](0019-threading-model-collect-safe-and-per-loop-affinity.md))
adds behaviour that only exists across threads, which sits uneasily with the
"one process, bounded iterations, no wall-clock" discipline above. It is split
in two so the default gate stays deterministic:

- **Deterministic invariants stay on the default gate** (`tests/test-async.sps`).
  The per-loop affinity check is exercised without a second thread by pointing a
  loop's owner field at a foreign thread id; `uv_async_send` is exercised from
  the loop thread itself (libuv permits it), so the send→wake path, coalescing
  tolerance, and the construction/exemption gating are all bounded and race-free.
- **Genuinely multi-threaded, timing-dependent proofs live off the default and
  memory gates** (`tests/test-threading-stress.sps`, `make test-threading`),
  exactly as `ROOT_TESTS` are gated behind `make test-root`. These fork real OS
  threads — a worker refused with `&uv-wrong-thread`, owner transfer to a second
  thread, and a worker pool posting through one async handle — and are the
  documented exception to the single-thread rule. They are kept off Valgrind
  because they are timing-dependent, not because threads and Valgrind conflict;
  the leak surface (one async handle's alloc/init/close) is covered by the
  deterministic suite under the memory gate instead.

## Amended 2026-09-28 (issue #35): same-process speed ratios on the default gate

The rule "no wall-clock anywhere" now has one bounded exception, recorded
here because the review of PR #36 found it undocumented.
`tests/test-native.sps` and `tests/test-stream.sps` time this binding's bulk
moves against libc and gate on the ratio. Those are `copy-in!`, `copy-out`
and `zero-out!`, and the verbs `uv-write!` and `uv-write*!`. Each move must
run within 3x of libc's own `memcpy`/`memset` over the same bytes
(`tests/uv-bulk.sls`). These rows guard #35's defect, a per-byte copy that
held the loop ~250 ms per 4 MiB write, and are worth nothing unless they run
where regressions land, so they stay on the default and memory gates.

Why the ratio does not reintroduce the flakiness the rule exists to prevent:

- **It is a ratio of two timings taken in the same process, not a duration
  against a budget.** The move and the reference are timed in seven
  alternating pairs, each after a fresh collection, and the least of each
  side counts. A slow machine or a burst of load slows both sides, so no
  absolute bound appears.
- **The reference is libc, not Scheme.** A byte-at-a-time Scheme loop's
  speed depends on how Chez compiled it: at `--optimize-level 3` it ran only
  4.8x slower than memcpy in the Linux image, and a bar calibrated against
  it failed correct code. libc runs the same code at every optimize level,
  and Memcheck replaces it for both sides alike.
- **The margin is wide on both sides.** Correct code measured 0.95–1.10x
  over five full runs on macOS, and 0.97–1.05x in the Linux image at
  optimize levels 0 and 3, and under Memcheck. A reverted Scheme loop
  measured 140x or more at the default level, and a C byte loop in a -O0
  build 13–385x. Full numbers are in `.plans/bulk-copy-mutation-log.md`.

The threaded proof that the copies stay plain lives off the gates, in
`tests/test-threading-stress.sps`, per the Companion above.
