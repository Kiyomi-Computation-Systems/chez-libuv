# The alloc callback answered in the shim (#45, item 5): mutation log

Evidence for `fix/alloc-in-shim`, on main after #46 (0e6a8e1), which did the
issue's other four items, and #47 (2128730). The probes and the second
mutation sweep ran on the branch while it was stacked on #46 at 09e8595.
#46's later commits change `call-with-uv-loop`'s exit and merge #47, a
test-tcp row. Neither touches the alloc path: of `src/` and the Makefile,
only `src/libuv/loop.sls` differs between the swept tree and the final one.
Every gate below ran again on the final rebase.

libuv calls the alloc callback before every read, and the binding's answer
never varied: the stream's own read buffer, allocated at the first read
start and freed by the close dispatcher. Through #46 the callback crossed
into Scheme anyway, through a locked trampoline, the seam and
`alloc-dispatch`. Now the shim answers it:

1. **`chez_uv_alloc_cb`** in `src/libuv-shim.c` copies a `uv_buf_t`
   descriptor that the handle's `data` field points at, or answers the
   empty buffer when `data` is NULL. `uv-read-start-native` hands libuv its
   address, which `native.sls` fetches through `shim-entry`.
2. **The read buffer is one block**: the descriptor, then the payload from
   the first 16-byte boundary after it (`install-read-buffer!` in
   `handles.sls`). `data` points at the block's head, and `read-dispatch`
   copies from the payload.
3. **The alloc trampoline, its slot and `alloc-dispatch` are gone**, and
   `dispatcher-names` narrows from fourteen names to thirteen.

ADR-0002 and ADR-0008 carry the amendments. Every probe and mutation ran on
a scratch clone outside the repo. Platforms: macOS arm64 (Chez 10.4.1
`tarm64osx`, libuv 1.52.1 via pkg-config, the dev build); Linux aarch64 in
`chez-libuv-valgrind:10.4.1` (Debian bookworm, vendored libuv 1.52.1,
`HAVE_PKG=no`); Linux x86_64 in `chez-libuv-valgrind-amd64:10.4.1`, under
emulation.

---

## The design, checked before building on it

The issue proposed the design. Each claim it rests on was checked first.

- **libuv never touches a handle's `data`.** In `vendor/libuv/src` the only
  reads and writes of a handle's `data` are `uv_handle_get_data` and
  `uv_handle_set_data` (`uv-data-getter-setters.c`). `uv__handle_init` and
  `uv__stream_init` leave it alone. The Windows sources set `data` only on
  requests embedded in a handle, and on a timer libuv allocates for itself.
- **The binding never used `data`,** and every handle block comes from
  `alloc-zeroed`, so `data` is NULL until the first read start.
- **libuv expects the empty answer.** `uv__read` (`unix/stream.c`) seeds
  `buf` with `uv_buf_init(NULL, 0)` before calling the alloc callback, and
  reports a NULL base or zero length to the read callback as `UV_ENOBUFS`.
  `alloc-dispatch` gave the same answer for a handle with no buffer.
- **The descriptor outlives every alloc callback.** It is part of the
  buffer's block, which only the close dispatcher frees. libuv stops reading
  at `uv_close` (`uv__stream_close` calls `uv_read_stop`), and the close
  callback is libuv's last call for a handle.
- **ADR-0002's line holds.** The function calls nothing, in libuv or in
  Scheme: it reads `handle->data` and copies one struct. It does not call
  `uv_buf_init`, which is a libuv function.
- **Its type is checked.** Scheme passes only the address, so a definition
  that drifted from `uv_alloc_cb` would compile. A file-scope typedef
  compares `&chez_uv_alloc_cb` with a `uv_alloc_cb` in a conditional
  expression. Under `-Werror`, clang 21 (`-Wpointer-type-mismatch`) and
  gcc 12 ("pointer type mismatch in conditional expression") both reject a
  wrong parameter type and a wrong return type, and accept the right one.

**The trampoline goes rather than stays.** Kept as a slot nothing calls, it
would be a locked foreign-callable no C code reaches. Its rows, which pinned
`alloc-dispatch`'s infallibility, would pin a dispatcher no read uses. UDP's
receive start takes the same `uv_alloc_cb`, so a UDP binding can hand libuv
the same function.

**Rejected:** a block of its own for the descriptor (a second allocation,
and a second lifetime to keep in step with the buffer's); a table in C
keyed by handle (a lookup per read, for what one field holds).

## Probes

On a scratch build of #46 (2e55a3c), then of a prototype of this design.
Fewest bytes over 2,000 calls, with the collector held off.

| | #46 | prototype |
|---|---|---|
| a uv-run that delivers a 16-byte read | 864 B (mean 1,290–1,323) | 448 B (mean 677–743) |
| the alloc slot, called alone | 352 B | no slot |

The prototype passed every suite except the four rows that named the slot:
the two frozen literals, the meter's arity table, and test-tcp's direct
`'alloc` calls.

**Time is not resolved.** Draining 16 MiB through a 4 KiB read buffer
(4,098 reads) took a median 32.1 ms on #46's head and 30.5 ms on this
branch, over 15 alternating runs each, with spreads of 26–36 ms and
26–46 ms. No per-read saving in time is claimed.

**Reads while another thread collects.** A probe drained 16 MiB through a
4 KiB buffer while a second thread allocated hard. Each of the 4,098 alloc
callbacks ran in C while the loop thread was deactivated inside the
collect-safe `uv_run`. In 3 of 3 runs the payload arrived byte for byte,
and the collector ran 78 to 109 times during the transfer.

## The rows

- **`tests/test-callback-alloc.sps`**
  - *a uv-run that delivers a 16-byte read, its alloc callback answered in
    the shim*: 448 B, bound 576. The reader has a loop of its own, so the
    metered run delivers that read and nothing else, and the write is made
    and completed on a second loop, off the meter. A one-second watchdog
    timer ends a run that waits for a read that never comes.
  - *a read through libuv costs over its direct delivery what a timer does,
    one crossing*: 80 B against a timer's 80 B, bound 120. See A02 below
    for why this row exists.
  - The arity table no longer names `alloc`.
- **`tests/test-tcp.sps`**: the direct `'alloc` dispatcher rows are
  replaced by rows that call `chez_uv_alloc_cb` as libuv does.
  - `data` points at the head of the handle's read buffer.
  - With `suggested` 1, the answer is the buffer's full length. The handle
    has been read into by then, so a payload overlapping its descriptor
    would already have overwritten it.
  - A row-unique pattern planted at the answer's base comes back through
    `on-data`.
  - A handle that never started reading gets the empty buffer.
  - Dropped: "a pointer it cannot resolve raises nothing". The C function
    looks nothing up, and libuv passes it only its own handles.
- **`tests/test-loop.sps`, `tests/test-native.sps`**: the thirteen-name
  literal.
- **`tests/test-shim-loading.sps`**, with the Makefile's `STALE_SHIM`: this
  shim's source compiled with `-Dchez_uv_alloc_cb=chez_uv_alloc_cb_withheld`,
  so it has every export but the new one, as an un-rebuilt shim would after
  an upgrade.
  - A control row requires it to load, without `chez_uv_alloc_cb` and with
    the renamed symbol.
  - Then the import must fail with `&uv-shim-unavailable`, naming the stale
    shim's path.

## Red

The new tests and Makefile against #46's `src/` at 09e8595: 14 new rows fail
by name.

- `test-callback-alloc`, three rows:
  - the arity table's seed;
  - the read row, at 864 B against 576;
  - the crossing row: `(read 496 timer 80 at-most 120)`.
- `test-loop` and `test-native`: the thirteen-name literal.
- `test-shim-loading`, five rows: the control and the four refusal rows. The
  stale shim loads, and nothing asks it for the callback.
- `test-tcp`, four rows: all four alloc-callback rows.

The arity row "every installed slot takes its trampoline's arguments with
no rest list" fails beside them because the table lacks `alloc`. It is not
a new assertion.

## Mutations

Each mutation was applied to the sweep base by exact text replacement that
aborts unless the target occurs once. Both shims were deleted and rebuilt
for every row, because Apple make compares whole-second mtimes. The owning
suites then ran. A mutation counts as caught only if every predicted row
failed by name.

Two sweeps ran. The first, before #46's 09e8595 landed, missed M02 and
mispredicted M05 (below). The second ran on the rebased code, renumbered A
so that its ids cannot be confused with #46's M-numbers. **It caught all 18,
each by the rows predicted.**

| id | mutation | caught by |
|---|---|---|
| A01 | alloc answered through a Scheme slot again (the #46 shape) | the read row (864 B); the crossing row; the arity seed; test-loop's and test-native's literal |
| A02 | a Scheme alloc callback with no seam: reads `data` and copies the descriptor | the crossing row (144 B against 120) |
| A03 | `data` points at the payload, not at the descriptor | test-tcp's data and answer rows, then every read row |
| A04 | `data` is never set | test-tcp's data and answer rows, then every read row |
| A05a | the descriptor in a block of its own, never freed | test-tcp's data row; Valgrind: 128 B definitely lost |
| A05b | the descriptor in a block of its own, freed once `data` points at it | test-tcp's read-integrity rows; under Valgrind, the data row and an invalid read in `chez_uv_alloc_cb` |
| A06 | the answer's length is libuv's suggestion | the answer row (length 1) |
| A07 | with `data` NULL, the answer's length is libuv's suggestion | the empty-buffer row |
| A08 | no NULL check | the empty-buffer row (`invalid memory reference`, contained) |
| A09 | the payload starts at the block's head, over the descriptor | the answer row, and the read rows |
| A10 | a read's delivery copies from the block's head | the planted-pattern row, and the transfer rows |
| A11 | the callback's address fetched with a bare `foreign-entry` | the stale shim's `uv-shim-unavailable` row and its naming row |
| A12 | `shim-entry` names the configured shim, not the one loaded | the stale shim's naming row |
| A13 | the fixture keeps the callback (no rename) | the control row and the four refusal rows |
| A14 | the signature drifts from `uv_alloc_cb`, in header and source alike | the build: "pointer type mismatch" |
| A15 | the descriptor's length covers the whole block, 16 B past the payload | the answer row; Valgrind: `read(buf) points to unaddressable byte(s)` |
| A16a | (test) the read row's write is skipped | the read row, `never-did-the-work`, after the 64 watchdog runs |
| A16b | (test) ...and the watchdog is not armed | hangs, killed at 120 s: the watchdog is what turns a lost read into a named failure |

Notes:

- **A02 found a hole, and the crossing row is the fix.** In the first sweep
  only the absolute read row stood, and it missed M02: a seam-free Scheme
  alloc callback costs 64 B a read, the crossing alone, under the 128 B
  margin. The crossing row compares two increments measured in the same
  run: a read through libuv over a read through its slot, against a timer
  through libuv over a timer through its slot. Each is one `uv-run` and one
  crossing, 80 B on all three platforms. The margin is half that, 40 B, so
  any second crossing shows.
- **A05b was mispredicted the first time.** The prediction was the data
  row. In a plain run, malloc hands the freed 16-byte descriptor straight
  back out, so the reads go wrong first and the integrity rows fail by name.
  test-tcp then aborts in plumbing (`uv-read-start!: socket is not
  connected`) before the data row runs. A05a (leaked) and A05b (freed)
  split the two halves. Under Valgrind, whose freelist keeps the freed
  block intact, the reads still work and the data row fails by name.
- **A08** passes `NULL` data straight to a dereference. The test calls the
  callback directly from Scheme, so the fault surfaces as a contained
  `invalid memory reference`. libuv itself never calls it on a handle
  without a buffer.

## The memory gate sees the descriptor

The real `test-memory` recipe, `make CHEZ=scheme HAVE_PKG=no test-memory
MEMORY_TESTS=tests/test-tcp.sps`, run in one container on the same build
(Linux aarch64, Valgrind 3.19):

| tree | Valgrind | test-tcp |
|---|---|---|
| control | 0 errors, 0 B definitely lost, 1,575 allocations | 207 pass |
| A05b, freed descriptor | 52 errors: `Invalid read of size 8 at chez_uv_alloc_cb (libuv-shim.c:234) by uv__read`, "0 bytes inside a block of size 16 free'd" | 1 fails, the data row |
| A05a, leaked descriptor | `128 bytes in 8 blocks are definitely lost` | 1 fails, the data row |
| A15, length past the payload | `Syscall param read(buf) points to unaddressable byte(s)`, "0 bytes after a block of size 65,552" | 1 fails, the answer row |

**macOS ASan does not see it.** The shim is not compiled with ASan, so
`chez_uv_alloc_cb`'s read of a freed descriptor goes unreported. Under ASan
A05b produced no report at all. Its read rows failed by name, and the suite
then aborted. The descriptor's lifetime is held by Linux Valgrind, the sole
memory gate (ADR-0003), and by the data row.

## Measurements

`tests/test-callback-alloc.sps`, the final tree. macOS arm64, Linux aarch64
and Linux x86_64 agree to the byte (three runs on each Linux leg):

| row | this branch | #46 (09e8595) | bound |
|---|---|---|---|
| a uv-run that delivers a 16-byte read | 448 B | 864 B | 576 |
| ...over a read's delivery through its slot (368 B) | 80 B | 496 B | 120 |
| ...and a timer's, for comparison: 400 B over 320 B | 80 B | 80 B | — |

The issue's own program (macOS arm64, three runs each) gave these figures:

- A write round read 1,413–1,414 B, against 1,955–1,957 B on #46's head, at
  the same 1.4–1.5 `uv-run`s a round. The round includes the peer's read
  and its alloc callback.
- The round's mean drops by more than the 416 B a single read sheds,
  because fewer guards split the stack and fewer fresh 64 KiB segments are
  charged to it.
- An idle run (16 B) and a timer's firing (529 B) did not move.

## Uncovered

- **`install-read-buffer!`'s order.** The handle owns the block before
  `data` points at it, so a raise in between would still leave the block for
  the close dispatcher to free. No raise is possible there, because an open
  stream's pointer is always valid, as #46's log found for the write verbs.
  Not pinned.
- **A crossing that allocated less than half a timer's increment** would
  pass the crossing row. On Chez 10.4.1 a crossing costs 64 B against a
  40 B margin. The row measures both increments on the Chez that runs it,
  so this changes only if a Chez makes crossings nearly free.

## Seen in passing

- During the first sweep, test-tcp's two abortive-close rows failed once
  under load: the close came through as EOF, not `ECONNRESET`. That sweep
  ran beside the macOS ASan suite. The rows depend on the peer's bytes
  being queued before the client closes, so they look load-sensitive. They
  are untouched here and passed on every other run.
- `.plans/callback-alloc-mutation-log.md`'s "Not changed" still names this
  item as a follow-up. It records #46 and is left as written.

## Gates

On `1ef2bb5`, the change rebased onto main, macOS arm64:

- `make test`: 20 suites pass.
- `make test-threading`: 12 rows.
- `make check-memory-gate` caught the planted libc overrun.
- `make test-memory` (ASan): all 20 suites pass.
- `make check-purity` holds, and `make check-help` is silent.
- `make prod`: check-prod PASS, with the type check compiled at `-O2`.

`make test-memory-docker` (Linux aarch64, Valgrind, vendored libuv 1.52.1),
from a `--no-hardlinks` clone of `1ef2bb5`, and before that of its
predecessors `3dbdff8` and `fd133a3`, with the same results:

- `check-memory-gate` caught the store overrun, the libc overrun and the
  leak, stayed consistent on the possible leak, and printed MEMORY GATE CAN
  FAIL.
- Every suite's own Valgrind summary: 0 errors and 0 B definitely lost, at
  778 to 5,403 allocations each (`test-callback-alloc.sps`: 5,403).
- The two forked children that `_exit` before exec report 131 B and 117 B
  definitely lost: the known fork artifacts, which never gate (ADR-0003).

Linux x86_64, plain, on `3dbdff8`: test-callback-alloc, test-shim-loading,
test-tcp, test-native and test-loop all pass.

## Release note

The shim gained an export, so a consumer must run `make build` again after
upgrading. An old shim is refused at import with `&uv-shim-unavailable`
naming it. No API changes. A patch release fits, as for #46.
