# A write's block freed when its payload shrinks: mutation log

Evidence for `fix/write-copy-leak`, built on #45's write verbs (PR #46).
Found by reading the code during #45 and confirmed here before any change.

The work began on `fix/callback-alloc` at 2e55a3c. It was rebased onto
7415410, #46's last head, which leaves `stream.sls` and `native.sls` as they
were, and then onto `main`'s 0e6a8e1, #46's squash, whose tree is 7415410's.
The probe and the comparison of fixes below ran on 2e55a3c. The rows' red,
the allocation rows, the mutation sweep and the gates ran again on 7415410
and on the fix rebased onto it, whose tree is df8d0f0's, and the figures
given for them are those. The review's fixes (see Review) change tests and
docs only, so `src/` is still df8d0f0's; the sweep and the gates ran again on
them.

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
  refusal: `uv-write!`'s `span-out-of-range`, or `uv-write*!`'s
  `segment-span-out-of-range`. It allocates exactly what the base does.
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

**The ranking measured the bracket, not the shapes** (found in review,
2026-10-05). `with-interrupts-disabled` expands to a `dynamic-wind`, which
costs 96 B per copy step. A bare `(disable-interrupts)` … `(enable-interrupts)`
pair, the bracket `begin-close!` uses, costs 0 B. Rebuilt with it, A, "one
status per write" and B all read 144 / 208 / 288 / 368 / 768 B for the shapes
above. So the 16 B held against B, and the follow-up's 96 B per segment, only
counted how many dynamic-winds each shape ran.

A still ties for cheapest, and with one primitive. Moving to the bare pair is
a separate decision with two costs:
- `dst` needs an upper bound. Today a `dst` of 2^64 or more gets past the
  check, and the FFI raises a bare condition from inside the step, which
  would leave interrupts disabled for good.
- A fault on an unmapped `dst` would leave them disabled too. `begin-close!`
  already accepts that trade-off.

## The rows

**`tests/test-stream.sps`'s shrinking-payload sweep** runs each verb in an
engine on a connected loopback pair. At the first expiry it overwrites the
payload with #xff and truncates it, then resumes. It has three variants:
`uv-write!`, `uv-write*!` with one span, and `uv-write*!` with the shrinking
span after a 7-byte one.
- Every run must either be refused by the verb under its own name, with no
  request registered or counted, or deliver to the peer exactly the bytes it
  was given. Each run's fill byte is unique to it, and never 0 or #xff.
- Each sweep starts at fuel 1 and stops at the first run no expiry reached,
  whatever its verdict. A broken build therefore fails by name instead of
  draining at every fuel up to the cap.
- The sweeps end at fuel 29, 42 and 53. On the fix, 21, 34 and 45 runs are
  refused (12, 19 and 28 of them after the block exists), each sweep has 7
  written runs, and the last run is untouched.

**`tests/test-tcp.sps`** gains three rows for the verbs' own up-front span
checks: an end of 2^70 through each verb, and an empty segment past the end.
The late refusal looks the same as those checks, so without these rows
nothing would notice a check removed (N1, N2 below).

**`tests/test-native.sps`** gains three rows for `try-copy-in!`:
- it answers `copied` for a span that fits, and copies it;
- it answers `span-out-of-range` for a span past the end, writing nothing on
  a destination seeded #x00 and on one seeded #xff;
- it raises for the caller's own mistakes rather than answering.

The `copy-in!` past-the-end row now checks the reason as well as the who.

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
| H1 | the sweep's fuel cap at 5 | each sweep began at fuel 1 with a refusal and ended in a run no expiry reached |
| H2 | the sweep truncates to the payload's own length | the same, and the bytes-sent row |
| N1 | `uv-write!`'s own `(<= end (bytevector-length bv))` deleted | test-tcp: an end past fixnum range is refused by uv-write!'s own check |
| N2 | `parse-write-segment`'s end bound deleted | test-tcp: a segment end past fixnum range …; an empty segment past the end … |
| N3 | `uv-write!` sends one byte short | the reach row and the bytes-sent row, by name, in 2.8 s (it was a 300 s HUNG with no row printed) |
| N3b | `uv-write!` drops its completion callback | the same two rows, in 5.3 s (it was about 944 s) |
| N4 | `try-copy-in!`'s fit check always passes, so copies read past the new end | the bytes-sent row (before the overwrite, test-stream passed 25/25) |
| N5 | `try-copy-in!` answers instead of raising for a malformed start or length | test-native: try-copy-in! raises for the caller's own mistakes rather than answering |
| N6 | `try-copy-in!` answers instead of raising for a null destination | the same |
| N7 | `try-copy-in!`'s `source-not-a-bytevector` reason renamed | the same |
| N8 | `copy-in!`'s past-the-end reason renamed | test-native: copy-in! rejects a span that runs past the end of the bytevector |
| N9 | `try-copy-in!`'s refusal zeroes the destination | test-native: try-copy-in! answers span-out-of-range … and writes nothing |
| H3 | the sweep starts at fuel 20 | each sweep began at fuel 1 with a refusal … |
| C1 | N4 with the overwrite removed | counterfactual, must pass: test-stream 25/25, so the overwrite is what catches N4 |

M2 and M5 ran through the real recipe, `make CHEZ=scheme HAVE_PKG=no
test-memory MEMORY_TESTS=tests/test-stream.sps`, with the unmutated tree as
its control (exit 0, nothing lost). How many of the two-segment blocks
Valgrind counts definitely rather than possibly lost varies by run (before
the rebase, M5 left all 47 definitely lost), but every run leaves blocks
definitely lost, so the gate fails on each.

Notes:

- **M8 also aborts `tests/test-stream.sps`.** The suite passes its first five
  rows, then stops at its top-level `uv-write!` to the unconnected pipe.
  That write is guarded for an errno only, and under M8 every write raises
  `span-out-of-range`. M8's catch is test-native's. The unguarded plumbing
  predates this PR.
- **The free itself is held by Valgrind alone**, like every other free in
  the binding (ADR-0003). CI's "linux (vendored + valgrind)" job runs `make
  HAVE_PKG=no test-memory` over every suite on each push; it ran green on
  this PR. `make test-memory-docker` is the local equivalent. A debug block
  counter at `alloc-zeroed`/`free!`, built as a shim counter class, would let
  plain `make test` see M2 and M5. That design change was left to the user.

## Uncovered

- **M11: `uv-write*!` checks empty spans too.** An empty span copies
  nothing, so the only difference is refusing an empty span whose
  bytevector shrank below its start. No row pins that either way; the
  sweep has no empty span. Equivalent for every other input (test-stream
  and test-tcp pass).
- **`uv-write!`'s end bound loosened by one byte** (`(<= end (+ 1 (bytevector-length bv)))`).
  The copy's late check then refuses such a span after allocating, with the
  same refusal, and frees the block. No plain row can see the allocation;
  N1's row holds the bound's presence, not its exact value. A debug block
  counter would make this a row.
- **Which refusals came after the block was allocated.** On the fix, both
  refusals look the same by design, so no plain row can show that the sweep
  reached the window. It is reached by construction: fuel steps by one from
  1, and the base's red names 12, 19 and 28 such runs. A block counter would
  make this a row too.

## Found on the way, not fixed here

Each of these was measured against a clean control, and each is now a task
of its own. All of them predate this PR.

**Verbs that read caller data again after allocating** (the same engine
sweep, aimed at other verbs):
- **`uv-getaddrinfo!`**:
  - **Leak.** It leaks its request block when the hints alist changes
    mid-call: `write-hints!` re-reads it after `alloc-zeroed`, outside any
    guard. With the family set to a bogus symbol at the first expiry, 47 of
    73 runs were refused with `unknown-hint-family`, and `leaks` counted 19
    leaked 224 B blocks.
  - **NUL bypass.** A NUL written into an already validated node string
    reaches C as a terminator: 61 of 73 runs resolved "0.0.0.127" for
    "127.0.0.1".
- **`uv-spawn!`** sizes its options block, allocates, and then walks the
  caller's data a second time to fill it:
  - **An argument string that grows** (64 ASCII characters made λ) overruns
    the block. Valgrind reports `Invalid write of size 1 … chez_uv_copy_in
    (libuv-shim.c:211) … 0 bytes after a block of size 196 alloc'd`, the
    child's `execve` reads past the block, and Valgrind then dies of a
    SIGSEGV on λ's bytes.
  - **A growing args or env list** overruns the block the same way: 41 of
    223 runs by 200 B for args, and 60 of 253 for env. It can also leave
    argv or envp unterminated.
  - **A growing stdio list** writes an extra container over argv[0], inside
    the block. Natively 98 of 221 runs fail with EFAULT. Under Valgrind they
    exec with an empty argv, and the gate stays green.
  - **NUL bypass.** A NUL written after the embedded-NUL check reaches the
    child: 78 of 155 spawns of `sh -c "exit 7"` ran "exit " instead.

**The write verbs under engines**, found in review:
- **Use after free.** `uv-write!`, `uv-write*!` and `uv-shutdown!` check the
  stream open and take its pointer at the top. If an engine suspends the verb
  and something closes the stream meanwhile, the resumed verb writes through
  the freed handle. Valgrind reports `Invalid read … in uv_write2 … inside a
  block of size 248 free'd`. When a new connection reuses the block, the
  bytes reach the wrong peer, and the callback reports success.
- **Abandoned engines.** An engine dropped rather than resumed between
  `alloc-zeroed` and `uv_write` loses the block, or leaves a `'write-req`
  registry entry that teardown never clears. The same holds for
  `uv-shutdown!`, and for `make-uv-timer`, where teardown then fails with
  EBUSY. This PR's fix covers only engines that are resumed.

**The macOS ASan arm cannot see an overrun made by the shim's own copies.**
The shim imports `___memcpy_chk` and `___memset_chk`, and a 16-byte overrun
planted through `chez_uv_copy_in` went unreported with ASan live
(`verbosity=1` banner). `check-memory-gate`'s macOS plant calls libc's
`memset` directly, so it passes all the same. That is why the spawn sweep
was clean on macOS.

## Review

/code-review (max), 2026-10-05: 15 verified findings.
- **Fixed here:**
  - the verbs' end bounds were no longer pinned (N1, N2);
  - the sweep hung instead of failing (N3, N3b);
  - the sweep was blind to an over-read (N4, C1);
  - the reach row claimed more than it checked (H3);
  - `try-copy-in!`'s raise-or-answer split was unpinned (N5–N7);
  - `copy-in!`'s reason was unpinned (N8);
  - the "writes nothing" row was unseeded (N9);
  - the ADR and this log misnamed `uv-write*!`'s reason, and this log had
    stale CI and M8 notes and an incomplete sibling survey.
- **Moved to their own tasks:** the use-after-free and abandoned-engine
  defects above, and the spawn and getaddrinfo re-reads.
- **Left to the user:**
  - the bare interrupt bracket (240 → 144 B per write, at the cost noted
    under "The fix");
  - a debug block counter;
  - test-stream's unguarded top-level plumbing (the M8 note).

## Gates

On 82ffbdb (the review fixes), macOS arm64:

- `make test`: 20 suites pass (test-stream 25, test-native 284, test-tcp
  210).
- `make test-threading`: 12 rows.
- `make test-memory` (ASan) passes all 20 suites, and `make
  check-memory-gate` still goes red on a planted libc overrun.
- `make check-purity` holds, and `make check-help` is silent.

`make test-memory-docker` from a `--no-hardlinks` clone of 82ffbdb:
- `check-memory-gate` caught all four planted defects and printed MEMORY
  GATE CAN FAIL.
- Every suite's own Valgrind summary shows 0 errors and 0 bytes definitely
  lost, at 778 to 5,324 allocations each (`test-stream.sps`: 1,414).
- The fork artifacts are the known 131 B and 117 B.

The real recipe on test-stream with M2 and with M5 still fails: 12 blocks
definitely lost, and 45 plus 2 possibly lost.

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
