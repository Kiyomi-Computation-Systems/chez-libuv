# A write's block freed when its payload shrinks: mutation log

Evidence for `fix/write-copy-leak`, built on #45's write verbs (PR #46).
Found by reading the code during #45 and confirmed here before any change.

The work began on `fix/callback-alloc` at 2e55a3c. It was rebased onto
7415410, #46's last head, which leaves `stream.sls` and `native.sls` as they
were, and then onto `main`'s 0e6a8e1, #46's squash, whose tree is 7415410's.
The probe and the comparison of fixes below ran on 2e55a3c. The rows' red,
the allocation rows, the mutation sweep and the gates ran again on 7415410
and on the fix rebased onto it, whose tree is df8d0f0's, and the figures
given for them are those.

`uv-write!` checks its span against the bytevector, allocates the request
block, and then calls `copy-in!`, which checks the span again in the same
interrupt-free step as the `memcpy` (#35). An engine's timer can expire
between the two checks, and its handler can truncate the bytevector (so can
another thread). `copy-in!` then raised `span-out-of-range` with the block
allocated and not yet registered, and nothing freed it. `uv-write*!` has the
same shape: its `place` loop copies each segment after the block exists.

Every probe and mutation ran on a scratch copy outside the repo. Platforms:
macOS arm64 26.6.2 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config,
the dev build); Linux aarch64 in the `chez-libuv-valgrind:10.4.1` image
(Debian bookworm, Valgrind 3.19, vendored libuv 1.52.1, `HAVE_PKG=no`), from
a `--no-hardlinks` clone.

---

## The leak, confirmed

A scratch probe ran each verb in an engine at fuel 1, 2, … on an unconnected
pipe, which refuses every write that reaches libuv, so `abandon-request!`
frees every block that gets that far. At the first expiry it truncated the
3,001-byte payload to 16 bytes, then resumed. The scan stopped at the first
run no expiry reached. On this branch's base (2e55a3c):

| scan | refused by the verb's check | refused by `copy-in!`, block allocated | refused by libuv |
|---|---|---|---|
| `uv-write!`, `[0, len)` | 9 | 12 | 73 |
| `uv-write!`, whole bytevector | 2 | 12 | 82 |
| `uv-write*!`, one span | 15 | 19 | 73 |
| `uv-write*!`, the span second | 0 | 28 | 86 |

The live counters and the registry were back to their baseline after every
run, because `count-write-req-new!` runs only after registration.

- **macOS `leaks --atExit`:** 259 malloc nodes alive at exit against 188
  without the truncation: exactly the 71 `copy-in!` refusals. `leaks` names 41
  of them leaked (3,584 B each, the size class of the 3,209 and 3,232 B
  blocks); a conservative scan finds the others' addresses still in memory.
  The control has 0 leaks.
- **Linux Valgrind:** 43 blocks definitely lost (137,987 B = 43 × 3,209 B,
  the one-span blocks) and 28 possibly lost (90,496 B = 28 × 3,232 B, the
  two-span blocks). The control has nothing lost, and 10 blocks
  (3,106 B) in use at exit.

**History.** v0.7.0 still zeroed and copied a byte at a time (#35). There
the same scans reached their fuel cap of 400 with 1,552 refusals named
`uv-copy-in!`, and `leaks` counted 1,211 leaked blocks. v0.1.0's
`uv-write!` has the same shape (read, not run: it predates pipes and
`uv-write*!`), beside a comment that says "EVERY CHECK ABOVE, THE FIRST
ALLOCATION BELOW".

## The fix, chosen by measuring

Bytes one call allocates, fewest of 64, on a connected loopback pair
(`tests/test-callback-alloc.sps`'s meter), macOS arm64, two runs each, every
run identical, on 2e55a3c. Segments are 16 bytes each. On 7415410,
test-callback-alloc reads the same 240 B and 304 B for the base and for A:

| shape | base (leaks) | **A: status** | A, one status per write | B: allocate inside the copy's step | B2: copy, then allocate |
|---|---|---|---|---|---|
| `uv-write!` of 16 B | 240 | **240** | 240 | 256 | 368 |
| `uv-write*!` × 1 | 304 | **304** | 288 | 304 | 464 |
| `uv-write*!` × 2 | 480 | **480** | 368 | 384 | 736 |
| `uv-write*!` × 3 | 656 | **656** | 448 | 464 | 1,008 |
| `uv-write*!` × 8 | 1,536 | **1,536** | 848 | 864 | 2,368 |
| a 4 MiB `uv-write!`, against libc | 1.0× | **1.0×** | 1.0× | 1.0× | 3.4× |
| blocks lost to the sweep (Valgrind) | 59 | **0** | 0 | 0 | 0 |

- **A** (chosen): the copy's step answers the refusal as a status
  (`try-copy-in!`), and each verb frees its block before raising its own
  `span-out-of-range`. It allocates exactly what the base does.
- **A, one status per write**: `uv-write*!` copies every span in one step.
  The cheapest shape measured, but it adds a second primitive whose packing
  must agree with the `place` loop's. It is an allocation change, not part
  of the leak fix; offered as a follow-up.
- **B**: the span's re-check, `alloc-zeroed` and the copy in one
  interrupt-free step, so a refusal comes before the block exists. 16 B more
  on every `uv-write!`, and two write-shaped primitives.
- **B2**: copy the span into a fresh bytevector before allocating. It fails
  two existing rows by name: "a uv-write*! of one 16-byte segment, the call
  alone, at most 432 bytes" (464 B), and test-stream's bulk row for
  `uv-write!`, whose bar is 3× libc (483 µs against 143 µs for 4 MiB). Its
  `uv-write!` meets its own bound only exactly (368 of 368 B).

## The rows

`tests/test-stream.sps`'s shrinking-payload sweep runs each verb in an
engine on a connected loopback pair, truncates the payload at the first
expiry, and resumes. Three variants: `uv-write!`, `uv-write*!` with one
span, and `uv-write*!` with the shrinking span after a 7-byte one. Every run
must be refused by the verb under its own name with no request registered
or counted, or deliver to the peer exactly the bytes it was given (a fill
byte unique to the run, never 0). The sweeps end at fuel 29, 42 and 53. On
the fix, 21, 34 and 45 runs are refused (12, 19 and 28 of them after the
block exists), 7 in each sweep are written, and the last is untouched.

`tests/test-native.sps` gains two rows for `try-copy-in!`'s answer.

**Red on the base (7415410, the tree of 0e6a8e1):** "a write whose payload shrank during the
call is refused by the verb itself, leaving no request" fails by name,
listing 12, 19 and 28 runs refused as `uv-copy-in!`. The real recipe, `make
CHEZ=scheme HAVE_PKG=no test-memory MEMORY_TESTS=tests/test-stream.sps`,
fails with 189,975 B in 59 blocks definitely lost (31 × 3,209 B +
28 × 3,232 B), make exit 2. On 2e55a3c, run straight under Valgrind, the
same suite left 58 blocks definitely lost and 1 possibly lost, exit 9.

**Green on the fix (df8d0f0's tree):** 25 rows. The same recipe exits 0 with
nothing lost and the control's 10 blocks (3,106 B) in use at exit.

## Mutations

Each mutation was an exact text replacement in a fresh copy of `src/` (or
`tests/`), aborted unless its target occurred once and re-checked after.
The owning suites ran against the copy; a mutation counts as caught only if
every expected row failed by name.

| id | mutation | caught by |
|---|---|---|
| M1 | `uv-write!` ignores the copy's status | a write the sweep let through sent the peer exactly the bytes it was given |
| M2 | `uv-write!` raises without freeing the block | plain rows pass; **`make test-memory` (Linux)**: 38,508 B in 12 blocks definitely lost (12 × 3,209 B), make exit 2 |
| M3 | `uv-write!` raises as `uv-copy-in!` | a write whose payload shrank … is refused by the verb itself, leaving no request |
| M3b | `uv-write!` raises `segment-span-out-of-range` | the same |
| M4 | `uv-write*!` ignores the copy's status | a write the sweep let through sent the peer exactly the bytes it was given |
| M5 | `uv-write*!` raises without freeing the block | plain rows pass; **`make test-memory` (Linux)**: 145,003 B in 45 blocks definitely lost and 6,464 B in 2 possibly lost (19 × 3,209 + 28 × 3,232 B in all), make exit 2 |
| M6 | `uv-write*!` raises as `uv-copy-in!` | a write whose payload shrank … is refused by the verb itself, leaving no request |
| M7 | `try-copy-in!` answers `copied` for a span that does not fit | test-native: try-copy-in! answers span-out-of-range …; copy-in! rejects a span that runs past the end …; both truncation-scan rows; test-stream: the bytes-sent row |
| M8 | `try-copy-in!` answers `#t` after copying | test-native: try-copy-in! answers copied …; copy-in! copies the requested span …, and four more |
| M9 | `copy-in!` ignores the status | test-native: copy-in! rejects a span that runs past the end …; both truncation-scan rows |
| M10 | the span check moved out of the interrupt-free step | test-native: copy-in! never copies past the end of a bytevector truncated during the call |
| H1 | the sweep's fuel cap at 5 | each sweep began before the verb's own check and ended in a run no expiry reached |
| H2 | the sweep truncates to the payload's own length | the same |

M2 and M5 ran through the real recipe, `make CHEZ=scheme HAVE_PKG=no
test-memory MEMORY_TESTS=tests/test-stream.sps`, with the unmutated tree as
its control (exit 0, nothing lost). How many of the two-segment blocks
Valgrind counts definitely rather than possibly lost varies by run (before
the rebase, M5 left all 47 definitely lost), but every run leaves blocks
definitely lost, so the gate fails on each.

Notes:

- **M8** also aborts `tests/test-stream.sps` before its first row: the
  suite's opening `uv-write!` to the unconnected pipe is guarded for an
  errno only, and under M8 every write raises `span-out-of-range`. Its
  catch is test-native's.
- **The free itself is held by Valgrind alone**, like every other free in
  the binding (ADR-0003). CI's Valgrind leg is billing-blocked, so
  `make test-memory-docker` is where it runs.

## Uncovered

- **M11: `uv-write*!` checks empty spans too.** An empty span copies
  nothing, so the only difference is refusing an empty span whose
  bytevector shrank below its start. No row pins that either way; the
  sweep has no empty span. Equivalent for every other input (test-stream
  and test-tcp pass).

## Found on the way, not fixed here

The same engine sweep against other verbs that read caller data again after
allocating:

- **`uv-getaddrinfo!` leaks its request block** when the hints alist
  changes mid-call: `write-hints!` re-reads it after `alloc-zeroed`, outside
  any guard. Setting the family to a bogus symbol at the first expiry: 47 of
  73 runs refused with `unknown-hint-family`, and `leaks` counted 19 leaked
  224 B blocks. The unmutated control has 0 leaks.
- **`uv-spawn!` overruns its options block** when an argument string grows
  between sizing and copying: `build-options-block` sizes every string with
  `string->utf8`, allocates, and encodes them again in `put-string!`. With
  the last argument's 64 ASCII characters made λ at the first expiry,
  Valgrind reports `Invalid write of size 1 … chez_uv_copy_in
  (libuv-shim.c:211) … 0 bytes after a block of size 196 alloc'd`; the
  child's `execve` reads past the block, and Valgrind then dies of a
  SIGSEGV at `0xCEBBCEBBD37419C2`, its own heap overwritten with λ's bytes.
- **The macOS ASan arm cannot see an overrun made by the shim's own
  copies.** The shim imports `___memcpy_chk` and `___memset_chk`, and a
  16-byte overrun planted through `chez_uv_copy_in` went unreported with
  ASan live (`verbosity=1` banner). `check-memory-gate`'s macOS plant calls
  libc's `memset` directly, so it passes all the same. The spawn sweep
  above was clean on macOS for this reason.

## Gates

On df8d0f0's tree, macOS arm64:

- `make test`: 20 suites pass.
- `make test-threading`: 12 rows.
- `make test-memory` (ASan) passes all 20 suites, and `make
  check-memory-gate` shows the recipe still goes red on a planted libc
  overrun. As found above, that arm cannot see an overrun made by the
  shim's own copies.
- `make check-purity` holds, and `make check-help` is silent.

`make test-memory-docker` (Linux aarch64, Valgrind, vendored libuv 1.52.1),
from a `--no-hardlinks` clone of that tree:

- `check-memory-gate` caught the store overrun, the libc overrun and the
  leak, stayed consistent on the possible leak, and printed MEMORY GATE CAN
  FAIL.
- Every suite's own Valgrind summary: 0 errors and 0 bytes definitely lost,
  at 778 to 5,324 allocations each (`test-stream.sps`: 1,409).
- The two forked children that `_exit` before exec report 131 B and 117 B
  definitely lost: the known fork artifacts, which never gate (ADR-0003).
