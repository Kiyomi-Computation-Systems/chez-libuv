# Bulk Copy Mutation Log (issue #35)

`copy-in!`, `copy-out` and `zero-out!` in `src/libuv/private/native.sls` each
moved their span one byte at a time in Scheme: a `foreign-set!` or
`foreign-ref` per byte, ~29 ns a byte. Each is now one call into the shim:
`chez_uv_copy_in` and `chez_uv_copy_out` (`memcpy`) and `chez_uv_zero`
(`memset`) in `src/libuv-shim.c`. Every argument check stays in Scheme, ahead
of the call. The decisions are amended inline: ADR-0002 gains a fifth kind of
shim export, and ADR-0009 records that the copy's cost was its implementation.
`tests/test-native.sps` gains eight rows (266 → 274) and one informational
line.

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
plus copying (121 + 125 ms) is the whole call, so the fix covers all three
helpers.

## Method

Per AGENTS.md, mutations ran in a scratch copy outside the repo. The copy held
`src/`, `tests/` and the `Makefile`; the `Makefile` is there because
test-native's path rows resolve `"Makefile"` in the working directory. Each
round broke one decision, then:

1. compiled the scratch shim from its own `libuv-shim.c` with the dev flags;
2. repointed the scratch `config.sls` at that shim, so test-native's
   "the shim this process loaded is the one config.sls names" row stays true;
3. ran test-native from the scratch directory and recorded its FAIL lines
   verbatim.

The first control loaded the scratch shim through `CHEZ_LIBUV_SHIM` instead,
and failed four path and identity rows that assume config.sls's own shim and a
`Makefile` in the working directory. The harness was fixed before any mutation
ran. The final control, with the unmutated scratch copy, gave 274 passes and
0 failures.

Before the rows were written, one probe checked that the comparison is fair: a
byte loop defined in a `--program` runs as fast as the library's. The ratio
was 0.99–1.00 in three runs at 64 KiB for each helper, so a helper reverted to
a loop measures ~1×, not faster than the reference.

## RED evidence (watched to fail first)

All eight rows were written and run before any fix. The three bulk rows failed
by name. The five content and edge rows passed, because the byte loops were
slow, not wrong:

```
FAIL copy-in! moves a span in bulk: over ten times faster than a byte-at-a-time loop
FAIL copy-out moves a span in bulk: over ten times faster than a byte-at-a-time loop
FAIL zero-out! clears a span in bulk: over ten times faster than a byte-at-a-time loop
  [informational] 64 KiB, helper vs byte-at-a-time loop, least of 5 (ns): copy-in! 1949000 vs 1928000 copy-out 1865000 vs 1870000 zero-out! 1893000 vs 1891000
# of expected passes      271
# of unexpected failures  3
```

GREEN after the fix: 274 passes, with `copy-in! 2000 vs 2228000 copy-out 2000
vs 3467000 zero-out! 1000 vs 2842000`. The monotonic clock ticks in whole
microseconds on macOS, so a sub-microsecond `zero-out!` can read 0. The verdict
handles that: 10 × 0 is still less than the loop.

## Mutation log

The S rows mutate the scratch `native.sls`, the C rows the scratch
`libuv-shim.c`, and the F row the scratch test file. Every mutation was
reverted. Each FAIL line below is the first named failure, quoted verbatim.

| # | Mutation | Verbatim named failure(s) |
|---|---|---|
| S1 | `copy-in!` body back to the byte loop | `FAIL copy-in! moves a span in bulk: over ten times faster than a byte-at-a-time loop` — only that row (3232000 vs 4116000 ns) |
| S2 | `copy-out` body back to the byte loop | `FAIL copy-out moves a span in bulk: over ten times faster than a byte-at-a-time loop` — only that row (2736000 vs 3464000 ns) |
| S3 | `zero-out!` body back to the byte loop | `FAIL zero-out! clears a span in bulk: over ten times faster than a byte-at-a-time loop` — only that row (2346000 vs 2544000 ns) |
| S5 | `copy-in!`'s span bound `(<= (+ start len) (bytevector-length bv))` → `#t` | `FAIL copy-in! rejects a span that runs past the end of the bytevector` — only that row. The shim trusts its arguments, so this check is the only guard, and an existing row still pins it |
| C1 | `chez_uv_copy_in` ignores `start` | `FAIL copy-in! copies the requested span, honouring start`, `FAIL copy-in! writes every byte of a 1 MiB span taken from a non-zero start`. Also `FAIL copy-out copies: mutating the foreign source afterwards leaves the result unchanged`, a knock-on from its shared fixture: its expected bytes assume `copy-in!` honoured start |
| C2 | `chez_uv_copy_in` stops at 64 KiB | `FAIL copy-in! writes every byte of a 1 MiB span taken from a non-zero start` — only that row. The 3-byte rows cannot see a truncation |
| C3 | `chez_uv_copy_out` stops at 64 KiB | `FAIL copy-out reads every byte of a 1 MiB span` — only that row |
| C4 | `chez_uv_zero` stops at 64 KiB | `FAIL zero-out! clears every byte of a 1 MiB span` — only that row |
| C5 | `chez_uv_copy_in` moves 1 byte for an empty span (`len ? len : 1`) | `FAIL copy-in! of an empty span at the end of its bytevector writes nothing` — only that row |
| C6 | `chez_uv_zero` one byte short | `FAIL zero-out! clears every byte it was given`, `FAIL alloc-zeroed returns zeroed memory even when the allocator hands back a dirty block`, `FAIL zero-out! clears every byte of a 1 MiB span` |
| C7 | `chez_uv_zero` one byte over, on every call | `Exception: invalid memory reference`, before any row reported. This proved nothing, so it was narrowed (below) |
| C7n | …only when `len == 64` | The same crash. The first 64-byte zero-out! row's block is exactly 64 bytes, so its overrun hits a neighbouring allocation |
| C7m | …only on the second 64-byte call, the guard-byte row's 65-byte block | `FAIL zero-out! does not write past the length it was given` — only that row |
| C8 | `chez_uv_copy_in` one byte over | `FAIL copy-in! writes nothing past the copied length`, `FAIL copy-in! of an empty span at the end of its bytevector writes nothing` |
| C9 | `chez_uv_copy_in` as a C byte loop (`for … dst[i] = src[start + i]`, -O0) | **Survives, by design** — 132000 vs 4114000 ns (31×). The bulk rows claim "one call into C, not a Scheme loop"; a C loop at -O0 runs ~2 ns/B, 4 MiB in ~8 ms, and is not the defect |
| F1 | the 1 MiB zero probe's seeding loop removed | `FAIL the 1 MiB zero-out! probe really was seeded non-zero first` — only that row. The clear row passed on the unseeded (fresh, already zero) block: that is the vacuous pass the seed row exists to catch |

## Properties with no row of their own

- **The absolute speed.** No row states a time budget. Each bulk row compares
  its helper with the byte loop on the same machine, a moment apart, and asks
  for 10×. The margin measured ~1000× natively, and ~900× under real Memcheck,
  which slows both sides alike (below).
- **Zero-length moves.** Chez passes an empty bytevector's storage as a
  non-null pointer. A probe returned the same non-null address for
  `(make-bytevector 0)` and the `#vu8()` literal; only `#f` passes 0. So a
  zero-length `memcpy` or `memset` has valid pointers and moves nothing. The
  shim adds no zero-length branch, so there is no decision to mutate. C5 shows
  the empty-span row notices a zero-length move that writes.

## Final gate

- `make test`: ALL SUITES PASSED (test-native 274).
- Every mutation ran in the scratch copy, and `git status` showed only the
  intended files modified.
- `make test-memory-docker` passed 17/17, but that proves nothing about this
  change. The gate's recipe runs `valgrind … timeout 900 scheme --program …`,
  so Memcheck checks `timeout` and never the Chez process: every suite
  reported "total heap usage: 2 allocs, 2 frees, 44 bytes allocated". A
  planted one-byte heap overrun went undetected in that shape (exit 0). It was
  caught with Valgrind wrapping `scheme` directly, and with
  `--trace-children=yes` (exit 9 both ways). The shape dates from 17b62b0
  (#14, 2026-08-30). Fixing the gate is separate work; for this change the
  suites were run under a real Memcheck, with `timeout` outside Valgrind — see
  the next bullet.
- **Real Memcheck:** Valgrind 3.19 on Linux arm64, in the gate's own image,
  with vendored libuv 1.52.1 (`HAVE_PKG=no`), the gate's own flags, and
  `timeout 2700 valgrind … scheme --program`. All 17 suites passed, each main
  process with 0 errors and 0 bytes definitely lost, now against Chez's real
  heap (test-native: 1,137 allocations, 3.4 MB).
  - Under Memcheck the bulk rows' informational line read `copy-in! 86166 vs
    76936959 copy-out 91000 vs 72078000 zero-out! 44042 vs 74964792`, about
    900×. Valgrind slows the helper and the loop alike.
  - One rerun: test-shim-loading reads the binary from `CHEZ`, which
    `make CHEZ=scheme …` exports and the hand-written loop did not. With
    `CHEZ=scheme` set it passed 24/24 with 0 errors.
  - The only errors anywhere are two forked children in test-process, each
    with one definite leak of 131 and 117 bytes. The suite passes, and its
    main process is clean. The same two leaks appear with `main`'s code
    (5271570, no `chez_uv_copy_in`), so they predate this change; the gate
    fix will need to decide what to do with them.
- `make test-threading`: STRESS SUITES PASSED.
- Release build guard, as CI runs it: `make prod` built the -O2 shim cleanly
  under `-Werror` and `check-prod` passed. After `make build`, `check-prod`
  refused the dev shim, as it should.
- `make check-pins` passes.
