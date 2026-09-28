# Bulk Copy Mutation Log (issue #35)

`copy-in!`, `copy-out` and `zero-out!` in `src/libuv/private/native.sls` each
moved their span one byte at a time in Scheme: a `foreign-set!` or
`foreign-ref` per byte, ~29 ns a byte. Each is now one call into the shim:
`chez_uv_copy_in` and `chez_uv_copy_out` (`memcpy`) and `chez_uv_zero`
(`memset`) in `src/libuv-shim.c`. Every argument check stays in Scheme, ahead
of the call.

The work ran in two rounds:

- **Round 1** made the fix and its first eight rows.
- **Round 2** answered the fifteen findings of a max-effort review of PR #36:
  - a libc reference for the timing rows;
  - rows for the write verbs;
  - an atomic span check;
  - a structured error for a stale shim;
  - a threaded row pinning the plain binding;
  - tighter content rows;
  - ADR and doc corrections.

The decisions are amended inline in ADR-0002 (a fifth kind of shim export),
ADR-0009 (the copy's cost was its implementation; the plain call's price; the
atomic span check) and ADR-0010 (same-process speed ratios on the default
gate).

## The defect, measured

Darwin arm64, Chez 10.4.1, at 5271570 (v0.7.0's code for these files). Each
figure is the least of five timings, repeated in two runs:

| | before | after |
|---|---|---|
| `copy-in!`, 4 MiB | 125 ms (29.8 ns/B) | 0.083–0.086 ms |
| `copy-out`, 4 MiB | 120 ms (28.6 ns/B) | 0.40–0.41 ms (mostly the bytevector allocation) |
| `zero-out!`, 4 MiB | 122 ms (29.1 ns/B) | 0.032–0.034 ms |
| one real `uv-write!` call, 4 MiB, loopback, the peer never reads | 247–251 ms | 0.41–0.54 ms |
| the same, 16 KiB | 1.0 ms | ~0.03 ms |

The issue asked for bulk `copy-in!` and `copy-out`, and attributed 125 ms of
its 254 ms stall to the copy. The other half was `zero-out!`, which is the same
per-byte loop: `uv-write!` and `uv-write*!` get their block from
`alloc-zeroed`, which zeroes all of it before `copy-in!` overwrites it. Zeroing
plus copying (122 + 125 ms) is the whole call, so the fix covers all three
helpers.

## Method

Per AGENTS.md, mutations ran in a scratch copy outside the repo. The copy held
`src/`, `tests/` and the `Makefile`; the `Makefile` is there because
test-native's path rows resolve `"Makefile"` in the working directory. Each
round broke one decision, then:

1. compiled the scratch shim from its own `libuv-shim.c` with the dev flags;
2. repointed the scratch `config.sls` at that shim, so test-native's
   "the shim this process loaded is the one config.sls names" row stays true;
3. ran the suites from the scratch directory, with `CHEZ` exported for
   test-shim-loading, and recorded their FAIL lines verbatim.

Loading the scratch shim through `CHEZ_LIBUV_SHIM` instead fails four path
and identity rows, so the harness never does. Every control, the unmutated
scratch copy, passed in full. The repo tree was checked clean after every
batch, including after the review's subagents.

## Round 1 — the fix

The eight rows were written and run first. The three timing rows, each
wanting its helper ten times faster than a byte-at-a-time Scheme loop, failed
by name (`copy-in! 1949000 vs 1928000 ns`, about 1:1). The five content and
edge rows passed, because the loops were slow, not wrong. After the fix:
274 passes.

| # | Mutation | Verbatim named failure(s) |
|---|---|---|
| S1–S3 | each helper back to its byte loop | its own timing row only, at 1.1–1.3× the loop *(rows since replaced, below)* |
| S5 | `copy-in!`'s span bound → `#t` | `FAIL copy-in! rejects a span that runs past the end of the bytevector` — only that row |
| C1 | `chez_uv_copy_in` ignores `start` | the 3-byte "honouring start" row and the 1 MiB copy-in! row; the aliasing row as a knock-on from their shared fixture |
| C2–C4 | each move stops at 64 KiB | its own 1 MiB content row only |
| C5 | an empty span moves 1 byte | the empty-span row only |
| C6 | `chez_uv_zero` one byte short | the 64-byte row, the dirty-allocator row, the 1 MiB row |
| C7 → C7m | `chez_uv_zero` one byte over | on every call it crashed at library init, proving nothing; narrowed to the guard-byte row's own call, only that row failed |
| C8 | `chez_uv_copy_in` one byte over | "writes nothing past the copied length", the empty-span row |
| C9 | `chez_uv_copy_in` as a C byte loop, -O0 | survived the 10× bar at 31× *(closed in round 2)* |
| F1 | the 1 MiB zero probe left unseeded | the seed row only |

(S4 was never used; the round-1 S series is S1, S2, S3, S5.)

## Round 2 — the review of PR #36

### What changed, by finding

| Finding | Change |
|---|---|
| copy-in!'s sign checks unpinned, now the only barrier before memcpy | rows for a negative start and a negative length (the length below `size_t`'s range, so a mutant fails by name instead of memcpying ~2^64 bytes); a row for copy-out's negative length |
| the 1 MiB copy-out row could pass on recycled heap | each content row seeds and reads back through libc, compares against a fresh or live reference with its own pattern multiplier |
| a direction-swapped copy passed the 1 MiB rows | the same: no row compares a helper's result with the helper's own operand |
| the plain-not-`__collect_safe` rule was only a comment | a threaded row in test-threading-stress.sps (off-gate, ADR-0010) |
| no row timed alloc-zeroed or the write verbs | uv-write! and uv-write*! rows in test-stream.sps, timed on the unconnected pipe |
| check-then-memcpy gap (engine + `bytevector-truncate!`) | span check and copy in one `with-interrupts-disabled` step; an engine-fuel scan row |
| the memory gate cannot fail | recorded here; fixed by PR #37 (below) |
| new rows called helpers outside rows | calls moved inside rows; the empty-span row guarded, checked under two seeds; the old 3-byte round trip and the read-net-u16 fixture no longer call a helper at top level |
| "wrote nothing before rejecting" became unfalsifiable | comment rewritten; recorded here and in the stage-1 log (M52, M52x below) |
| the 10× bar was miscalibrated both ways | the reference is libc, not a Scheme loop (next section) |
| docs/api.md's read-buffer claims were a per-byte-loop artifact | corrected, with Leg B redone drain-only; spike/flow/FINDINGS.md noted |
| ADR-0002 gave the wrong reason for the shim | rewritten; its Consequences line amended |
| timing rows on the default gate vs ADR-0010 | ADR-0010 amended |
| the plain call's GC hold unrecorded | ADR-0009 and docs/api.md's uv-write! row |
| a stale shim failed the import with a raw assertion | every shim binding goes through `shim-procedure`, which raises `&uv-shim-unavailable`; a test-shim-loading row; the README says to rebuild after upgrading |

### RED evidence (the rows were run before the library changed)

- test-native, 280 pass / 1 fail:
  `FAIL copy-in! never copies past the end of a bytevector truncated during the call`.
  The scan saw `(refused ×7, read-past-the-end, finished-before-any-expiry)`:
  at fuel 8 the copy read the heap past the truncated bytevector.
- test-shim-loading, 26 pass / 1 fail:
  `FAIL a loadable library without the shim's exports: raises uv-shim-unavailable, not a raw dlopen error`.
- GREEN after the change: test-native 281, test-shim-loading 27, test-stream 18,
  test-threading-stress 10, and `make test` ALL SUITES PASSED.

### The timing rows' reference: libc, not a Scheme loop

A byte-at-a-time Scheme loop's speed depends on how Chez compiled it, so a bar
set against it failed correct code at `--optimize-level 3` and passed a C byte
loop. `tests/uv-bulk.sls` now times each move against libc's own `memcpy` or
`memset` over the same bytes, and wants it within 3×.

The prototype at 1 MiB measured each helper and verb as a ratio to libc:

| where | helpers and verbs | Scheme byte loop |
|---|---|---|
| macOS, levels 0 and 3 | 0.92–1.19 | 1311–5051 (level 0), 50–165 (level 3) |
| Linux image, level 0 | 0.91–1.06 | 140–165 (copies), 3557–3970 (zero) |
| Linux image, level 3 | 0.98–1.55 (the 1.55 is `zero-out!`'s 9 µs against 6 µs) | 4.7 (copies), 164 (zero) |
| Memcheck | 0.97–1.04 | 570–1779 |

The Linux level-3 loop at 4.7× is why the bar is 3, not higher. The rows use
4 MiB spans, which make fixed overhead negligible.

Measured on the final rows at 4 MiB:

- macOS, five full runs: 0.95–1.10.
- Linux image: 0.99–1.01 at level 0, 1.00–1.05 at level 3, 0.97–1.00 under
  Memcheck.

Two changes cut the variance:

- **A collection before every timed run.** Over 20 copy-out verdicts the worst
  ratio fell from 1.59 to 1.22, with medians of 1.04 and 1.03.
- **Paired rounds.** A mutation batch run beside another session's Docker jobs
  measured an unmutated uv-write*! at 2.14×. The verdict now alternates the
  reference and the move over seven rounds, so a stretch of load lands on
  both.

### Mutations (round-2 ids restart; they name different edits)

S mutates the scratch `native.sls` (S5 `stream.sls`), C the scratch
`libuv-shim.c`, F a test fixture. Each FAIL is quoted verbatim, and each
mutation was reverted.

| # | Mutation | Verbatim named failure(s) |
|---|---|---|
| S1 | copy-in! as a Scheme loop | `FAIL copy-in! moves a span at libc speed: within 3x of memcpy over the same bytes` (140924000 vs 143000 ns); in test-stream both verb rows (145788000 vs 472000; 139331000 vs 147000) |
| S2 | copy-out as a Scheme loop | `FAIL copy-out moves a span at libc speed: within 3x of allocating and memcpy over the same bytes` (137035000 vs 369000) |
| S3 | zero-out! as a Scheme loop | `FAIL zero-out! clears a span at libc speed: within 3x of memset over the same bytes` (134402000 vs 33000); both verb rows |
| S4 | alloc-zeroed zeroing with a Scheme loop | test-native 281/0: no helper row reaches it. test-stream: `FAIL uv-write! moves its payload at libc speed: within 3x of allocating, zeroing and copying it` (126425000 vs 469000) and `FAIL uv-write*! moves its segments at libc speed: within 3x of allocating, zeroing and copying them` (128551000 vs 144000) |
| S5 | uv-write! copying one byte per copy-in! call (stream.sls) | uv-write!'s row only (89158000 vs 281000); uv-write*! passes. The first attempt used `foreign-set!`, unbound in stream.sls, and failed at import for the wrong reason, so it was narrowed |
| S6 | no `(>= start 0)` in copy-in! | `FAIL copy-in! rejects a negative start even when start+len is in range` — only that row |
| S7 | no `(>= len 0)` in copy-in! | `FAIL copy-in! rejects a negative length even when start+len is in range` — only that row, no hang |
| S8 | no `(>= len 0)` in copy-out | `FAIL copy-out rejects a negative length` — only that row |
| S9 | span check and copy not atomic (round 1's shape) | `FAIL copy-in! never copies past the end of a bytevector truncated during the call` — only that row |
| S10 | span bound `<` for `<=` | `FAIL copy-in! of an empty span at the end of its bytevector writes nothing`, plus the copy-in! timing row and the scan's seed row (a full-span copy is refused); 278/3, and the suite completes. Before the read-net-u16 fixture was reseeded with `foreign-set!`, this mutant aborted the suite there with exit 255 |
| S11 | `shim-procedure` without the entry check | `FAIL a loadable library without the shim's exports: raises uv-shim-unavailable, not a raw dlopen error` — only that row |
| S12 | `__collect_safe` on the two copy bindings | test-native 281/0: single-threaded rows cannot see it. test-threading-stress: `FAIL no collection completes while copy-in! is inside its foreign call` and `FAIL no collection completes while copy-out is inside its foreign call`, in 3/3 runs. The unmutated control passed 10/10 in 3/3 runs |
| M52 | zero-out!'s length check removed | `FAIL zero-out! rejects an inexact length`, `FAIL zero-out! rejects a negative length`. "wrote nothing before rejecting" passes: Chez refuses 3.0 at the `size_t` argument before C runs |
| M52x | the same, plus a Scheme loop | adds `FAIL zero-out! wrote nothing before rejecting` and the zero-out! timing row |
| C1 | copy_in ignores start | the 3-byte "honouring start" row, the aliasing row (knock-on), the 1 MiB copy-in! row |
| C2 | copy_in stops at 64 KiB | `FAIL copy-in! writes every byte of a 1 MiB span taken from a non-zero start` — only that row |
| C3 | copy_out stops at 64 KiB | `FAIL copy-out reads every byte of a 1 MiB span` — only that row; the GC-timing stress is below |
| C4 | zero stops at 64 KiB | `FAIL zero-out! clears every byte of a 1 MiB span` — only that row |
| C5 | an empty span moves 1 byte | the empty-span row only; with 400,000 dead 24-byte `#xff` bytevectors allocated just before it, still 5/5. The single-seed round-1 row passed 5/5 there, per the review's sweep |
| C6 | zero one short | the 64-byte row, the dirty-allocator row, the 1 MiB zero row |
| C7m | zero one over, on the guard-byte row's call only | `FAIL zero-out! does not write past the length it was given` — only that row |
| C8 | copy_in one over | "writes nothing past the copied length", the empty-span row, and the copy-in! timing row (its overrun runs off the 4 MiB block, and the raise lands inside the row) |
| C9 | all three as C byte loops, -O0 | all three helper rows (4191000 vs 69000; 4361000 vs 335000; 9257000 vs 24000) and both verb rows (13491000 vs 94000; 13466000 vs 95000) |
| C10 | copy_out direction swapped | `FAIL copy-out reads every byte of a 1 MiB span`, plus the 3-byte rows |
| C11 | copy_in direction swapped | `FAIL copy-in! writes every byte of a 1 MiB span taken from a non-zero start`, plus the 3-byte and scan rows |
| C12a | copy_in swapped only above 64 KiB | the 1 MiB copy-in! row; test-stream, test-tcp, test-echo and test-flow all pass, so only this row sees it |
| C12b | copy_out swapped only above 64 KiB | the 1 MiB copy-out row; the same four suites pass |
| F1 | the 1 MiB zero probe left unseeded | `FAIL the 1 MiB zero-out! probe really was seeded non-zero first` — only that row |
| F2 | the scan never truncates | `FAIL the truncation scan spanned the check: some runs refused, the last untouched` — only that row |
| F3 | the address probe passes `#f` | `FAIL an empty bytevector reaches C as a non-null pointer` — only that row |
| O3 | no mutation, `--optimize-level 3` | test-native 281, test-stream 18, on macOS and in the Linux image |
| O3+S1 | S1 at `--optimize-level 3` | the copy-in! timing row (8404000 vs 99000) |

**C3 against shifted collection timing.** Each run used a wrapper that set
`collect-trip-bytes`, or pre-allocated garbage, before loading the suite:

- trips of 327680, 262144, 2621440 and 8388608, five runs each;
- 7.5 and 7.9 MiB of garbage, five runs each.

The new row caught the truncated copy-out in **30/30** runs. In the same
harness, the round-1 row passed vacuously in 1/20 runs at trip 327680; the
review's verifier had seen 11/20, and 4/10 with garbage.

## Properties with no row of their own

- **The absolute speed.** The rows hold a ratio to libc, never a time budget.
- **C and Scheme agreeing on `size_t`.** The prototypes and the
  `foreign-procedure` signatures both say `size_t`, and nothing checks that
  they agree. No row of practical size can tell `size_t` from a 32-bit type:
  it would need a span over 4 GiB. A narrowing on the Scheme side fails
  loudly, because Chez refuses a value past `unsigned-32`. One on the C side
  would silently truncate at 2^32. Recorded, not tested.
- **Another thread truncating a bytevector mid-copy.** The atomic step covers
  interrupts on the calling thread only. Truncation from another thread is
  that program's own race.
- **The collect-safe rows detect by scheduling.** Correct code passes
  deterministically, since a plain call refuses every concurrent collect.
  Detection of the mutant was 3/3 but is not guaranteed, so the rows live off
  the gate (ADR-0010).

## Held below the review's cap, not changed

- **c-string->string still copies per byte.** Its strings are short and on
  cold paths.
- **Write blocks are still zeroed in full before the payload overwrites
  them.** That costs ~10% of a 4 MiB write, but the zeroing means a short-copy
  bug would send zeros rather than stale heap bytes.
- **Addresses at or above 2^64** raise Chez's malformed `$oops` assertion
  rather than `&uv-invalid-argument`. No library caller can produce one.

## Final gate

- `make test`: ALL SUITES PASSED (test-native 281, test-stream 18,
  test-shim-loading 27).
- `make test-threading`: STRESS SUITES PASSED (10, including the two
  collect-safe rows).
- **Real Memcheck on the final tree.** Run in the gate's own image with
  vendored libuv 1.52.1, the gate's flags, and `timeout 2700 valgrind …
  scheme --program`:
  - all 17 suites pass, every main process with 0 errors;
  - under Memcheck test-native passes 281 and test-stream 18, with bulk
    ratios 0.97–1.00;
  - the only errors are two forked children in test-process, each with one
    definite leak of 131 or 117 bytes. The same two appear on `main`'s code,
    so they predate this change.
- **The Linux image without Valgrind:** test-native 281 and test-stream 18, at
  optimize levels 0 and 3.
- **The memory gate, before and after #37.** Until #37, `make test-memory`
  ran `valgrind … timeout 900 scheme`, so Memcheck checked `timeout`, never
  Chez: every suite reported "total heap usage: 2 allocs, 2 frees, 44 bytes",
  and a planted overrun exited 0. The shape dates from 17b62b0 (#14).

  After #37 (fe303c5) was merged into this branch, both arms are live and
  pass with this change:
  - `make test-memory-docker` exits 0. Its `check-memory-gate` caught the
    planted store overrun, libc overrun and leak ("MEMORY GATE CAN FAIL").
    All 17 suites then passed under Memcheck on `scheme` itself: test-native
    281 with bulk ratios 1.00, test-stream's verbs at 1.01–1.02. The two
    forked-child leaks are non-gating per #37.
  - macOS `make test-memory` (ASan) exits 0: test-native 281,
    test-shim-loading 27, test-stream 18, no AddressSanitizer reports.
    `make check-memory-gate` there caught the planted libc overrun.
- **Release build guard, as CI runs it.** `make prod` built the -O2 shim
  under `-Werror` and `check-prod` passed. After `make build`, `check-prod`
  refused the dev shim. `make check-pins` passes.
