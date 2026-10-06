# The alloc callback answered in the shim (#45, item 5): mutation log

Evidence for `fix/alloc-in-shim`, on main after #46 (0e6a8e1), which did the
issue's other four items, and #47 (2128730). The probes and the second
mutation sweep ran on the branch while it was stacked on #46 at 09e8595.
#46's later commits change `call-with-uv-loop`'s exit and merge #47, a
test-tcp row. Neither touches the alloc path: of `src/` and the Makefile,
only `src/libuv/loop.sls` differs between the swept tree and the final one.
Every gate below ran again on the final rebase.

#48's review (2026-10-06) found defects in that first design, and its fixes
moved the descriptor from the head of the read buffer into the stream's
handle block. The sections from "The design" to "The memory gate" record
the first design as it was checked and swept, except where they say
otherwise. "Review" records the fixes and their evidence, and holds where
the two disagree. The review's sweep ran before the branch was rebased
onto #49 (a0ea0ca), which changed the write verbs and nothing on the read
path; the final gates ran after it.

libuv calls the alloc callback before every read, and the binding's answer
never varied: the stream's own read buffer, allocated at the first read
start and freed by the close dispatcher. Through #46 the callback crossed
into Scheme anyway, through a locked trampoline, the seam and
`alloc-dispatch`. Now the shim answers it:

1. **`chez_uv_alloc_cb`** in `src/libuv-shim.c` copies a `uv_buf_t`
   descriptor that the handle's `data` field points at, or answers the
   empty buffer when `data` is NULL. `uv-read-start-native` hands libuv its
   address, which `native.sls` fetches through `shim-entry`.
2. **The descriptor lives in the stream's handle block**, after libuv's
   handle at the first 16-byte boundary, and `data` points at it from the
   moment the stream is made (`attach-stream-descriptor!` in `handles.sls`).
   The first read start fills it with the read buffer, which is exactly its
   payload, in one interrupt-free step with the record
   (`install-read-buffer!`). The close dispatcher empties it before freeing
   the buffer (`free-read-buffer!`). The first design put it at the head of
   the read buffer.
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
  `alloc-zeroed`, so `data` is NULL until the binding sets it. The first
  design set it at the first read start; the final one sets it when it
  makes a stream.
- **libuv expects the empty answer.** `uv__read` (`unix/stream.c`) seeds
  `buf` with `uv_buf_init(NULL, 0)` before calling the alloc callback, and
  reports a NULL base or zero length to the read callback as `UV_ENOBUFS`.
  `alloc-dispatch` gave the same answer for a handle with no buffer.
- **The descriptor outlives every alloc callback.** In the first design it
  was part of the buffer's block, and in the final one it is part of the
  handle's. Only the close dispatcher frees either. libuv stops reading at
  `uv_close` (`uv__stream_close` calls `uv_read_stop`), and the close
  callback is libuv's last call for a handle.
- **ADR-0002's line holds.** The function calls nothing, in libuv or in
  Scheme: it reads `handle->data` and copies one struct. It does not call
  `uv_buf_init`, which is a libuv function.
- **Its type is checked.** Scheme passes only the address, so a definition
  that drifted from `uv_alloc_cb` would compile. The first design's check,
  a file-scope typedef comparing `&chez_uv_alloc_cb` with a `uv_alloc_cb`
  in a conditional expression, held only under `-Werror`; the review
  replaced it (K6 below).

**The trampoline goes rather than stays.** Kept as a slot nothing calls, it
would be a locked foreign-callable no C code reaches. Its rows, which pinned
`alloc-dispatch`'s infallibility, would pin a dispatcher no read uses. UDP's
receive start takes the same `uv_alloc_cb`, so a UDP binding can hand libuv
the same function.

**Rejected:** a block of its own for the descriptor (a second allocation,
and a second lifetime to keep in step with the buffer's); a table in C
keyed by handle (a lookup per read, for what one field holds). The review
rejected the head of the read buffer too (K3 below).

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
26–46 ms. No per-read saving in time is claimed. (A burst of short reads
later resolved it: about 24% less a read. See "Review", "Time".)

**Reads while another thread collects.** A probe drained 16 MiB through a
4 KiB buffer while a second thread allocated hard. Each of the 4,098 alloc
callbacks ran in C while the loop thread was deactivated inside the
collect-safe `uv_run`. In 3 of 3 runs the payload arrived byte for byte,
and the collector ran 78 to 109 times during the transfer.

## The rows

As the first design shipped them. "Review" lists what changed and what was
added.

- **`tests/test-callback-alloc.sps`**
  - *a uv-run that delivers a 16-byte read, its alloc callback answered in
    the shim*: 448 B, bound 576. The reader has a loop of its own, so the
    metered run delivers that read and nothing else, and the write is made
    and completed on a second loop, off the meter. A watchdog timer ends a
    run that waits for a read that never comes: one second then, 50 ms now
    (K16).
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
  a second crossing shows, unless the timer's own increment drifts too
  (Uncovered).
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

## Review (2026-10-06)

A max-effort review of b2b4c1f reported 15 findings. An independent probe
confirmed 13 and found K5 and G2 plausible. All 15 are fixed. Moving the
descriptor into the handle block (K3) removed four of them by construction.

| id | finding | fix | held by |
|---|---|---|---|
| K1 | An engine suspended between recording the read buffer and pointing `data` at it left a stream answering `UV_ENOBUFS` to every read, for good once the engine was dropped (fuel 22–23). | `data` points at the descriptor from the stream's creation, and the install fills the descriptor and the record in one interrupt-free step. | the install sweep (R01) |
| K2 | A second start made while the first was suspended between its check and its install leaked a buffer (fuel 10–21; 10–13 on #46). | The step checks again, and a start that loses frees and uncounts its block. | the install sweep (R02, R03) |
| K3 | The 16-byte header took a 64 KiB buffer into macOS's 81,920 B size class: 65,823 B resident per reading stream became 82,289 B, over 2,000 streams. | The descriptor is in the handle block, whose macOS size class has room for it. | the payload row (R24) |
| K4 | A read delivered to a stream with no buffer copied from address 16, past `copy-out`'s null check. | Delivery copies from the buffer itself, with no offset. | the bufferless-read row (R07) |
| K5 | `free-read-buffer!` left the descriptor naming the freed buffer. | It empties the descriptor first, in one interrupt-free step with the record. | the free row (R04) |
| K6 | The type check's `? 1 : -1` could never pick -1, so only `-Werror` enforced it. | One object declared twice, as a `uv_alloc_cb` and as a pointer to the callback's own typedef: a constraint violation, an error without `-Werror`. | the build (R12, R12b) |
| K7 | test-callback-alloc's new read start ran outside any row, so a failed seed aborted the suite (exit 255). | Both read starts are gated on their seed. | R20, R20b, R20c |
| K8 | No row pinned the block's size: an undersized block passed every plain suite. | A row asks the allocator for the block's size. | the fits row (R14, R15) |
| K9 | test-tcp called the callback by name, not what `uv-read-start!` hands libuv, and its fallback for a shim without the callback was dead. | A row reads `uv_stream_t`'s `alloc_cb` field on a reading stream (`OFFSETOF_UV_STREAM_T_ALLOC_CB`, a new shim constant); the fallback is gone. | the wiring row (R13, R21) |
| K11 | `data`'s one-writer rule was a comment. | `tests/test-source-rules.sps` counts `uv-handle-set-data` call sites in `src/`. | R08 |
| K12 | `shim-entry` restated `shim-procedure`'s refusal. | `shim-procedure` expands through `shim-entry`. | R10, R11 |
| K13 | The stale-shim fixture copied the shim's link line. Separately, 46 of 47 shim entries could be resolved bare with every suite green. | One canned recipe, `LINK_SHIM`, links both shims. `tests/test-source-rules.sps` requires every shim entry `native.sls` resolves to go through `shim-procedure` or `shim-entry`. | R09, R10 |
| K15 | Every read recomputed the payload offset through a cross-library lookup, 5–9 ns. | Gone: the read buffer is the payload. | by construction |
| K16 | A one-second watchdog on each of 64 calls made a lost read take 64 s to report. | 50 ms: a `'once` run polls for I/O before it runs a timer. | R19 |
| G2 | `install-read-buffer!` accepted sizes from −15 to 0. | `alloc-zeroed` sees the real size again, and refuses them. | the size row (R16) |

`uv-buf-set!` also gained the checks its siblings have (a null destination,
a negative or inexact value), held by a test-native row (R17).

**One more, found while fixing K3: the close guard.** With the descriptor in
the handle block, a start suspended before its install while its stream
closed would, resumed, write the descriptor into the freed block and leave a
buffer no close frees. The install's step now also requires the stream to be
open, and a start that lost its install to a close is refused as closed
(`ensure-read-buffer!`). A second sweep, the close sweep, holds both (R22,
R23). Under Valgrind, R22 reads as `Invalid write of size 8 … 256 bytes
inside a block of size 272 free'd`: the descriptor, at `align-16` of
Linux's 248 B `uv_tcp_t`.

The close sweep found an older hole too, which it does not fix. A start
suspended after its install, once `handle-pointer` has answered, resumes
into `uv_read_start` with the freed handle's address. Valgrind reported it
on the first version of the sweep (`Invalid read of size 4 at
uv_read_start … 88 bytes inside a block of size 272 free'd`). main has the
same shape. It is the engine split #49's review found in the write verbs,
which `uv-read-start!` shares, and it is left to a change of its own. The
sweep now drops such a start instead of resuming it.

### The rows

- **`tests/test-tcp.sps`**
  - *uv-read-start! hands libuv the shim's own alloc callback*, read back
    from the field libuv calls (K9), and *...and these rows call that same
    callback*.
  - *a stream's data points at its descriptor, at the first 16-byte boundary
    after libuv's handle*, for a reading stream and a never-read one.
  - *libuv's alloc callback answers the stream's own read buffer, whole, at
    its full length*, and *the length libuv is told fits inside the block it
    reads into* (K8).
  - *the read buffer's block is its length, within one malloc granule*
    (K3). Only macOS can see a header there: glibc rounds to 16 bytes, and
    both memory gates' allocators answer the size requested.
  - *a handle whose data is NULL gets the EMPTY buffer too*: a timer, since
    every stream has a descriptor now.
  - *freeing a stream's read buffer empties its descriptor* (K5).
  - *install-read-buffer! refuses a size that is not positive, installing
    nothing* (G2), and *a read delivered to a stream with no read buffer is
    refused by name* (K4).
  - The install sweep: a first start suspended at every fuel value from 1
    to 120, then a second start, then the first resumed. The descriptor
    must agree with the record at the suspension and after, and nothing may
    leak (K1, K2). A reach row requires it to have caught a start before its
    install, one after, and one run to the end.
  - The close sweep (above), with its own reach row.
- **`tests/test-source-rules.sps`** (new, pure; K11, K13): the one-writer
  rule and the checked-entry rule. Seeded rows prove each checker reports
  what it should, and liveness rows prove the scan read the real tree.
  `tests/uv-source.sls` is the source reader it shares with
  `tests/test-require-threaded.sps`.
- **`tests/test-native.sps`**: `uv-buf-set!`'s refusals.
- **`tests/test-callback-alloc.sps`**: both read starts gated (K7), and the
  50 ms watchdog (K16).
- **`tests/test-shim-loading.sps`**: the naming row reads the child's
  stderr, which `check-rejected` now answers.

### Red

The new rows against b2b4c1f's `src/`, with only what they import added
(two exports, the shim's `alloc_cb` offset, and the Makefile's shared link
line): eight rows fail by name in test-tcp. They are the data, answer,
fits, free, size and bufferless rows, the install sweep and its reach row. The sweep's leaks then fail three counter rows downstream. At
fuel 22–23 the sweep caught K1 (the record set, the answer `(0 0)`), and at
fuel 10–21 K2 (a buffer left after close). The rows added after that run
(the payload row and the close sweep) were watched to fail through their
mutations, R24 and R22–R23.

### Mutations

Sweep 3, on a scratch clone of the branch, with sweep 2's harness: an
exact-once replacement per edit, both shims deleted and rebuilt for every
row, then the owning suites. A mutation counts as caught only if every
predicted row fails by name. Rows that fail beside them are recorded, not
hidden: most are the counter rows downstream of a leak.

It ran four times as the fixes grew, each time on the tree as it then
stood. The last run, on 66d7b5f (the final code before the rebase onto
#49), caught every mutation by the rows predicted. Earlier runs missed two,
neither a hole in the rows. R15's first edit called `quotient`, which
`handles.sls` does not import, so the suite died of an unbound identifier.
R02, in the second run, hit the load abort under "Seen in passing". Both
were fixed and run again.

| id | mutation | caught by |
|---|---|---|
| R01 | the install without its interrupt-free step | the install sweep |
| R02 | the install's step does not check again for a buffer | the install sweep |
| R03 | a start that loses the install neither frees nor uncounts its block | the install sweep |
| R04 | `free-read-buffer!` leaves the descriptor naming the block | the free row |
| R05 | `make-uv-tcp` never attaches the descriptor | the data and answer rows |
| R06 | the descriptor 16 B further on, its block grown to match | the data row |
| R07 | a read's delivery copies from 16 B into the block | the planted-pattern and bufferless rows |
| R08 | a second writer of `data`, in `uv-tcp-keepalive!` | test-source-rules' one-writer row |
| R09 | one shim entry resolved by a bare `foreign-procedure` | test-source-rules' entry row |
| R10 | the callback's address fetched by a bare `foreign-entry` (A11) | the entry row; the stale shim's refusal and naming rows |
| R11 | `shim-entry` names the configured shim, not the one loaded (A12) | the stale shim's naming row |
| R12 | the callback's type drifts in its typedef, header and definition | the build: "redeclaration of 'chez_uv_alloc_cb_type_check' with a different type" |
| R12b | the definition and header drift, the typedef kept | the build: "conflicting types for 'chez_uv_alloc_cb'" |
| R13 | a seam-free Scheme alloc callback handed to libuv (A02) | the wiring row; the crossing row |
| R14 | the descriptor's length 16 B more than its block (A15) | the answer and fits rows |
| R15 | the read buffer allocated at half its length | the fits row |
| R16 | `install-read-buffer!` accepts a size of 0 | the size row |
| R17 | `uv-buf-set!` without its checks | test-native's refusal row |
| R18 | (test) `check-rejected` answers stdout, not stderr | the naming row |
| R19 | (test) the read row's write is skipped (A16a) | the read and crossing rows, in 6.7 s on the last run, 4.5–8.5 s across the runs (66 s with the one-second watchdog) |
| R20 | (test) the read pair's accept never records its peer | the seed, read and crossing rows; the suite completes, exit 1 |
| R20b | (control) R20, with the read start ungated | the suite aborts, exit 255, with no summary: the gate is what keeps it running |
| R20c | (test) the direct pair's accept never records its peer | its seed and delivery rows; the suite completes |
| R21 | alloc answered through a Scheme slot again (A01) | the read, crossing and wiring rows; both literals |
| R22 | the install's step does not check that the stream is open | the close sweep |
| R23 | a start that lost to a close is not refused as closed | the close sweep |
| R24 | a 16-byte header in front of the read buffer again | the payload row |
| R25 | `make-uv-tcp` allocates libuv's handle alone, under ASan | the room row |
| R26 | `make-uv-pipe` allocates libuv's handle alone, under ASan | the room row |
| R25p | R25 in a plain macOS run | nothing, as predicted: the 320 B size class hides it (next section) |

R12's build ran with the project's flags. The review's K6 probe had already
shown the same drift rejected under `-w` and without `-Werror`, by clang 21
and by gcc 12 and 13.

### The memory gate sees the final layout

The real recipe, `make CHEZ=scheme HAVE_PKG=no test-memory
MEMORY_TESTS=tests/test-tcp.sps`, in one container per batch on one build
(Linux aarch64, Valgrind 3.19, vendored libuv). The first four ran before
the room row was added, the last after it.

| tree | Valgrind | test-tcp |
|---|---|---|
| control | 0 errors, 0 B definitely lost, 3,021 allocations | 219 pass |
| R22, the install's open check removed | `Invalid write of size 8`, "256 bytes inside a block of size 272 free'd"; 393,216 B in 6 blocks definitely lost | the close sweep row fails |
| R14, the descriptor 16 B longer than its block | `Syscall param read(buf) points to unaddressable byte(s)`, "0 bytes after a block of size 65,536" | 5 rows fail: answer, fits, free, the install sweep and its reach row |
| R06, the descriptor 16 B further on, its block grown to match | 0 errors | the data row fails: only the placement is wrong |
| R25, `make-uv-tcp` allocating libuv's handle alone | `Invalid write of size 8`, then `Invalid read of size 8 at chez_uv_alloc_cb (libuv-shim.c:250)`, "8 bytes after a block of size 248 alloc'd"; 1,276 errors | the room row fails |

R25 shows the gate sees the shim's reads in the final layout, as A05b did
in the first. Where a block's size class hides the missing room, only an
allocator that answers the size requested can see it:

- **macOS, plain**: R25 and R26 pass every row. A 264 B `uv_tcp_t` and a
  280 B `uv_pipe_t` take 320 B either way.
- **macOS, ASan**: the room row fails by name. ASan's `malloc_size` answers
  264 B for R25's block and 288 B for the control's.
- **Linux, plain**: R26 fails the room row by name. R25 dies first, with
  `invalid memory reference`: the descriptor lands in the next chunk's
  header.
- **Linux, Valgrind**: as in the table.

The first time R25 ran under ASan it passed every row, because `timeout`
stood between the preload and `chez`. ASan loaded into `timeout`, as
AGENTS.md's memory-gate trap describes. With the preload on `chez` itself
the row failed. The sweep's ASan rows run `chez` directly.

### Time

The review measured what the first log left open. Through the same
`__collect_safe` foreign-procedure, the Scheme alloc trampoline took
304–312 ns a call, the shim's callback 58–63 ns, and a trivial C call
63–72 ns. End to end, a burst of reads (a 16-byte buffer, 512 B writes, 32
libuv reads per `uv-run`) took 1,298–1,353 ns a read on #46 and 990–1,046 ns
on b2b4c1f: about 300 ns, 23%, less. The burst runs were at load averages
of 8 to 11.

The final layout, measured after #48 merged (2026-10-06), is about as
fast as b2b4c1f: about 24% less a read than #46.

- **Method.** The same burst on macOS arm64, interleaved, four runs per
  tree. Each run gives five measurements, each the mean over 5,000 rounds
  of 32 reads, so each tree has 20.
- **Trees.** #46 (0e6a8e1), and 66d7b5f, the final layout before the
  rebase onto #49. #49 changed only the write verbs, and neither tree has
  it.
- **Load.** The load average was 6.

| tree | ns a read | median |
|---|---|---|
| #46 | 1,319–1,531 | 1,362 |
| the final layout | 1,003–1,143 | 1,029 |

The ranges do not overlap. The final layout's read path differs from
b2b4c1f's only by the payload offset the review timed at 5–9 ns a read
(K15), now gone.

Two earlier runs of the same pair resolved nothing. They ran at load
averages of 40 to 150, from work outside this branch, and spread both
trees over 2.5–68 µs a read.

## Measurements

`tests/test-callback-alloc.sps`. macOS arm64, Linux aarch64 and Linux x86_64
agree to the byte (three runs on each Linux leg). The review's fixes moved
none of these: the final tree measures the same on macOS arm64.

| row | this branch | #46 (09e8595) | bound |
|---|---|---|---|
| a uv-run that delivers a 16-byte read | 448 B | 864 B | 576 |
| ...over a read's delivery through its slot (368 B) | 80 B | 496 B | 120 |
| ...and a timer's, for comparison: 400 B over 320 B | 80 B | 80 B | — |

The issue's own program (macOS arm64, three runs each) gave these figures:

- A write round read 1,413–1,414 B on the first design, against
  1,955–1,957 B on #46's head, at the same 1.4–1.5 `uv-run`s a round. The
  round includes the peer's read and its alloc callback. On the final tree
  it read 1,408–1,409 B at 1.1–1.2 runs a round; each idle run is 16 B.
- The round's mean drops by more than the 416 B a single read sheds,
  because fewer guards split the stack and fewer fresh 64 KiB segments are
  charged to it.
- An idle run (16 B) and a timer's firing (529 B) did not move.

## Uncovered

- **An engine dropped while the install allocates leaks the block.**
  `install-read-buffer!` allocates and counts the block before its
  interrupt-free step, because allocating can raise and the step must not.
  An engine that runs out of fuel there and is never resumed leaves the
  block allocated and counted, with nothing pointing at it. A resumed one
  frees it if it lost. The class is older than this branch: the write
  verbs, for one, allocate their request block before libuv owns it.
  Accepted, not pinned.
- **The write into a freed handle block is seen by the memory gate only.**
  The close sweep sees a start that installed after its stream closed by
  the buffer it leaves behind. The descriptor write that comes with it is
  Chez's own store into freed memory, which a plain run cannot see; R22
  under Valgrind is below.
- **A crossing that allocated less than half a timer's increment** would
  pass the crossing row. On Chez 10.4.1 a crossing costs 64 B against a
  40 B margin. The row measures both increments on the Chez that runs it,
  so this changes only if a Chez makes crossings nearly free.
- **The crossing row's yardstick is code under test** (K20, found by the
  review and confirmed as plausible). The bound is one and a half times
  the timer's increment, measured in the same run. A timer path that grew
  by 16 B over its direct delivery would raise the bound from 120 B to
  144 B, which is exactly what A02 costs, and hide it. The absolute rows
  hold each path's own bytes, so such a drift fails `timer-through-libuv`'s
  row first only if it exceeds that row's 128 B margin.

## Seen in passing

- During the first sweep, test-tcp's two abortive-close rows failed once
  under load: the close came through as EOF, not `ECONNRESET`. That sweep
  ran beside the macOS ASan suite. The rows depend on the peer's bytes
  being queued before the client closes, so they look load-sensitive. They
  are untouched here and passed on every other run.
- `.plans/callback-alloc-mutation-log.md`'s "Not changed" still names this
  item as a follow-up. It records #46 and is left as written.
- **During the review's sweeps the machine ran at load averages of 44 to
  120**, from parallel work outside this branch. test-tcp's early loopback
  rows failed in several runs, and once the suite aborted at top-level
  plumbing (`stream-read-buf: never-accepted is not of type
  uv-stream-record`, exit 255) before the rows a mutation targeted. That
  plumbing dates from v0.3 and is left for a follow-up, with the
  abortive-close rows above. Every mutation it hit was run again.

## Gates

On `725db7a`, this branch rebased onto #49 (a0ea0ca), macOS arm64, at load
averages of 100 to 180:

- `make test`: 21 suites pass, among them test-tcp's 223 rows and
  test-native's 283.
- `make test-threading`: 12 rows.
- `make check-memory-gate` caught the planted libc overrun.
- `make test-memory` (ASan, the runtime named in its log): all 21 suites
  pass.
- `make check-purity` holds for all four pure suites, test-source-rules
  among them, and `make check-help` is silent.
- `make prod`: check-prod PASS, with the type check compiled at `-O2`.

`make test-memory-docker` (Linux aarch64, Valgrind, vendored libuv 1.52.1),
from a `--no-hardlinks` clone of the same code:

- `check-memory-gate` caught the store overrun, the libc overrun and the
  leak, stayed consistent on the possible leak, and printed MEMORY GATE CAN
  FAIL.
- Every suite's own Valgrind summary: 0 errors and 0 B definitely lost, at
  778 to 5,411 allocations each (`test-callback-alloc.sps`: 5,411).
- The two forked children that `_exit` before exec report 131 B and 117 B
  definitely lost: the known fork artifacts, which never gate (ADR-0003).

Linux x86_64 (emulated), plain, on the same code: test-callback-alloc
measures the same bytes as on arm64 (448 B, 80 B over a direct read, 80 B
for a timer), and test-tcp (223 rows), test-native, test-loop,
test-shim-loading, test-source-rules and test-stream all pass. A first
run of test-shim-loading failed every probe because the command left
`CHEZ` unset, so the suite spawned `chez`, which that image does not
have. With `CHEZ=scheme`, as `make` exports it, all 32 rows pass.

The first design's gates ran on `1ef2bb5` with the same results.

## Release note

The shim gained an export, so a consumer must run `make build` again after
upgrading. An old shim is refused at import with `&uv-shim-unavailable`
naming it. No API changes. A patch release fits, as for #46.
