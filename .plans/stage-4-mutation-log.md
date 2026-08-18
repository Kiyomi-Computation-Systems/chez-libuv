# Stage 4 Mutation Log

Task 8 opens this log (Task 9 appends to it). It covers the TCP **write**
path — `src/libuv/tcp.sls`, the TCP handle record, the request record, the
four Stage 4 dispatchers and the read-buffer arm of the close dispatcher in
`src/libuv/private/handles.sls`, the TCP/stream entry points, the four stream
wrappers and the `int` / network-byte-order boundary helpers in
`src/libuv/private/native.sls`, and the `(libuv)` facade's new re-exports —
proving that every decision those files encode has an assertion in
`tests/test-tcp.sps`, `tests/test-lifecycle.sps`, `tests/test-native.sps`,
`tests/test-loop.sps`, `tests/test-timer.sps` or `tests/test-facade.sps` that
fails, **by name**, when the decision is broken.

## Provenance of this stage's red/green history — read this first

The session that implemented Stage 4 was killed by repeated server errors
part way through, at the point where the `(libuv)` facade was being wired up.
Its working tree survived (uncommitted) and a second session audited,
finished and verified it. That matters for one specific claim this log would
otherwise make implicitly:

- **The red→green transcript of the individual assertions was NOT observed by
  the finishing session.** The suites were already green in the inherited
  tree. Nothing in this log claims otherwise.
- **One genuine red artifact survives**, captured by the interrupted session
  before the implementation existed:
  `…/scratchpad/stage4/red-run.txt` — `make test` with the suites present and
  `src/libuv/tcp.sls` absent:

  ```
  === tests/test-facade.sps ===
  Exception: attempt to reference unbound identifier make-uv-tcp …
  === tests/test-lifecycle.sps ===
  Exception: library (libuv tcp) not found
  === tests/test-loop.sps ===
  FAIL a request entry is NOT in its loop's live-handle snapshot
  FAIL registry-register! rejects an entry whose loop is not a uv-loop
  FAIL the refused registration left nothing behind in the registry
  FAIL registry-deregister! returns the count to where it was
  FAIL the registry is back to its starting size
  === tests/test-tcp.sps ===
  Exception: library (libuv tcp) not found
  === tests/test-timer.sps ===
  Exception: library (libuv tcp) not found
  SUITE FAILED
  ```

  That is evidence of test-before-code ordering and of the registry rows
  failing by name; it is **not** per-assertion red evidence for the tcp suite,
  whose rows could not run at all in that state.
- **Everything else in this log was run fresh by the finishing session**, on
  the tree as committed. The mutation results below are the real per-assertion
  evidence AGENTS.md asks for, and they were produced after the fact rather
  than alongside each assertion. Where a mutation was NOT caught it is
  recorded as not caught.

## Method

Identical to `.plans/stage-{1,2,3}-mutation-log.md`, and to AGENTS.md's "a
test is not finished when it passes; it is finished when you have watched it
fail":

1. The seven files under test were copied, once, to a scratch tree *outside*
   this repository —
   `…/scratchpad/stage4f/mutation-scratch/src/{libuv.sls,libuv/{tcp,loop,handle,timer}.sls,libuv/private/{handles,native}.sls}`
   — each with a `.pristine` sibling. The repo's own files were never edited
   during mutation testing.
2. Each mutation edits *only* the scratch copy, breaking exactly one
   decision. The driver refuses to apply an edit whose anchor text is not
   unique in the file, so no mutation can land somewhere other than where it
   was aimed.
3. The six suites run from the repo, unmutated, against the mutated library:

   ```
   CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/src:$REPO/tests:$REPO/build/scheme-libs" \
     chez --program $REPO/tests/test-tcp.sps
   ```

   `$SCRATCH/src` first makes Chez resolve the mutated library there; every
   other library still resolves from `$REPO/src`.
4. Failing test names are recorded verbatim with the process exit status. A
   180 s per-suite cap turns a mutation that blocks in `uv-run 'default` into
   a recorded `TIMEOUT` rather than a stuck run.
5. The scratch copy is restored from `.pristine` and all six suites are re-run
   to confirm green before the next mutation.

Driver, mutation set and raw output:
`…/scratchpad/stage4f/{mutate4.py,mutations4.json,mutations-run.txt,results4.json}`.

**Baseline** (before any mutation, and reconfirmed green after every one):

| Suite | Assertions | Exit |
|---|---|---|
| `tests/test-tcp.sps` | 93 | 0 |
| `tests/test-native.sps` | 170 | 0 |
| `tests/test-lifecycle.sps` | 60 | 0 |
| `tests/test-timer.sps` | 132 | 0 |
| `tests/test-loop.sps` | 106 | 0 |
| `tests/test-facade.sps` | 37 | 0 |
| `tests/test-conditions.sps` (not in the driver's set) | 89 | 0 |
| `tests/test-shim-loading.sps` (not in the driver's set) | 19 | 0 |

The set below was run **twice**, in full. The first pass found three
survivors; two of them were answered by new assertions (see "What the first
pass changed", below) and the whole set was then re-run against the
strengthened suites. **The table reports the second pass**; the first pass's
raw output is kept alongside it as `mutations-run-pass1.txt`.

## Summary

Failing test names are quoted verbatim from the SRFI-64 runner. Where a
mutation produced a cascade, the **first** name listed is the one that names
the broken decision; the rest are consequences. Every mutation was confirmed
**restored-green** before the next was applied.

| # | Decision under test | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 1 | The write block is freed by its completion dispatcher, never before `uv_write` (design spec §7) | `free!` the block immediately before the `uv_write` call | **process death**, exit −5 / −6 (SIGTRAP / SIGABRT) | no assertion — libuv reads the freed block and macOS's allocator traps; see the note below |
| 2 | A completion dispatcher POPS the registry entry | `registry-deregister!` dropped from `complete-request!` | FAIL, exit 255 | `&uv-invalid-argument who: uv-registry-register! reason: pointer-already-registered` — in all three loop-driving suites, when a later `foreign-alloc` reuses the address |
| 3 | The block is freed BEFORE `on-complete` runs (design spec §7) | the callback moved ahead of the free in `complete-request!` | FAIL, exit 1 | "the write block was already freed when on-complete ran"; "the write request was already deregistered when on-complete ran"; "the shutdown request was already deregistered when on-shutdown ran" |
| 4 | `uv-write!` validates its span BEFORE any allocation | span check moved after the alloc, the registration and the counter | FAIL, exit 1 | "an out-of-range span is refused before anything is allocated"; "a negative start is refused, naming who and why"; "an end before start is refused, naming who and why" |
| 5 | A failed `uv_accept` routes the fresh client through the NORMAL close path (design spec risk #8) | `close-handle!` dropped from `uv-accept!`'s failure guard | FAIL, exit 1 | "the failed accept's client was closed through the normal close path" — and *only* that one |
| 6 | `sin_port` is read in NETWORK byte order (`ntohs` by hand) | the two bytes of `read-net-u16` swapped (host order) | FAIL, exit 1 (+2 TIMEOUT, 1 exit 255) | "read-net-u16 decodes two bytes in NETWORK order, not host order"; "read-net-u16 reads at the offset it is given"; then `test-tcp`/`test-lifecycle` TIMEOUT and `test-facade` dies in `uv-tcp-nodelay!` — nothing can connect to a byte-swapped port |
| 7 | The freeing site bumps the counter for the `'tcp` kind (design spec §10) | the `'tcp` arm of `count-handle-free!` deleted | FAIL, exit 1 | "seed: three tcp handles are live -- server, client and peer" (+3 in `test-tcp`, +5 in `test-lifecycle`) |
| 8 | The close dispatcher frees the per-handle read buffer (design spec §6) | `free-read-buffer!` dropped from `close-dispatch` | FAIL, exit 1 | "the close dispatcher freed the handle's read buffer"; "the close dispatcher zeroed the read-buffer field"; "a full collection after teardown leaves every counter at zero" |
| 9 | The live-handle snapshot contains HANDLES only, never requests | kind inclusion reverted to Stage 2's exclude-`'loop` test | FAIL, exit 1 | "a request entry is NOT in its loop's live-handle snapshot" — and *only* that one |
| 10 | A registry entry's loop field is validated where it is written (the seam guard's last resort) | the `uv-loop?` check deleted from `registry-register!` | FAIL, exit 1 | "registry-register! rejects an entry whose loop is not a uv-loop"; "the refused registration left nothing behind in the registry" (+2 balance rows) |
| 11 | A nonzero callback status becomes an `&uv-errno-error` OBJECT, not `#f` and not a raise | `status->err` answers `#f` for every status | FAIL, exit 1 | "a write too large for the socket buffer, cancelled by a close, reports 'ECANCELED"; "a refused connection is delivered as an &uv-errno-error object, not raised"; "its errno is a symbol, and the symbol is 'ECONNREFUSED" |
| 12 | Each stream wrapper bakes in ITS OWN trampoline entry point | `uv-write-native` given the connect trampoline | FAIL, exit 1 | "the write block was already freed when on-complete ran" (+7 in `test-tcp`, +4 in `test-lifecycle`) — write completions arrive through the connect dispatcher, which cannot resolve them |
| 13 | A synchronous native failure deregisters what it registered | `abandon-request!` frees without popping the registry entry | FAIL, exit 1 | "the exchange loop tore down cleanly"; "the pending-write loop tore down cleanly"; "the cancelled-write loop tore down cleanly"; "the registry is back to its starting size" |
| 14 | Every `uv_tcp_*` verb refuses a handle of another kind | the `uv-tcp-record?` check deleted from `require-open-tcp` | FAIL, exit 1 | "uv-tcp-getsockname-port refuses something that is not a handle"; "uv-tcp-bind! refuses a handle of another kind, naming who and why"; "uv-write! refuses a handle of another kind, naming who and why" |
| 15 | The co-allocated members are 16-byte aligned inside the block | `align-16` is the identity | **NOT CAUGHT** — equivalent mutant on this platform | none; see "Uncovered, and why" |
| 16 | `uv-write!` copies the requested SPAN, not the head of the bytevector | `copy-in!` reads from offset 0 instead of `start` | FAIL, exit 1 | "the copied bytes are the requested span, not the head of the bytevector" — **survived the first pass**; this row was added because of it |
| 17 | `uv-listen!` stores its callback BEFORE the native call | the store moved after `uv_listen` | **NOT CAUGHT** — unobservable in a single-threaded loop | none; see "Uncovered, and why" |
| 18 | The four Stage 4 dispatchers are installed through the seam, by name | `'write-done` left holding Stage 3's raising stub | FAIL, exit 255 | `Exception in write-done: this callback type is not implemented in this version` — in all three loop-driving suites |
| 19 | `uv-tcp-connect!` registers its request block | `registry-register!` skipped for the connect request | **TIMEOUT** ×3 | every connect completion becomes an orphan event, so no connect ever completes and all three loop-driving suites block |

## What the first pass changed

The first pass ran against the suites exactly as the interrupted session left
them, and three mutations survived: 15, 16 and 17. Two were answered with new
assertions rather than written off, and the whole set was re-run:

- **16 is the one that mattered.** The inherited span-write row asserted only
  that a span write *completed*; a copy that read from offset 0 instead of
  `start` completes just as cleanly. Reading is Stage 5, so the peer's view is
  not available — but the write block is, right up until its completion frees
  it. `tests/test-tcp.sps` now reads the in-flight block's own `uv_buf_t`
  (length, that the payload pointer addresses memory *inside* the request's
  own block, and the bytes themselves via `copy-out`) **before** the loop is
  run. Mutation 16 now fails by name. This closes, on this side of the wire,
  the payload-integrity gap Stage 4 otherwise had to defer to Stage 5's 1 MiB
  transfer.
- **6 was caught only weakly.** Its first-pass evidence was a `TIMEOUT` plus a
  crash in `test-facade` — a real failure, but one that names nothing.
  `tests/test-native.sps` now decodes bytes this suite chose (`#xb4 #x39` →
  46137 big-endian, 14772 host-endian: two values that cannot be confused),
  so the byte-order decision now fails **by name** in a suite that needs no
  socket at all. The end-to-end fixed-port row in `test-tcp.sps` stays as the
  second, independent detector.
- **15 and 17 were not answered**, because neither can be — see below.

## Uncovered, and why

- **Mutation 15 — `align-16` is an equivalent mutant on this platform.**
  Measured here: `uv_req_size(UV_WRITE)` = 192, `uv_req_size(UV_CONNECT)` =
  96, `uv_req_size(UV_SHUTDOWN)` = 80, `sizeof(uv_buf_t)` = 16,
  `sizeof(sockaddr_storage)` = 128. Every request size is already a multiple
  of 16, so rounding up is the identity function *here* and no assertion can
  distinguish the two. The rounding is kept because it is a portability
  check, not a local one: on any target where `uv_req_size` is not
  16-aligned, an unaligned `uv_buf_t` or `sockaddr_storage` inside the block
  is exactly the kind of fault that shows up as a bus error on one
  architecture and nowhere else. Recorded rather than deleted, per AGENTS.md.
- **Mutation 17 — the listen-callback store ordering is unobservable
  single-threaded.** libuv can only deliver a connection from inside
  `uv_run`, and nothing runs the loop between `uv_listen` returning and the
  next Scheme statement, so "stored before" and "stored after" are
  indistinguishable in this binding as it exists. The ordering is kept
  because it is the same rule `uv-timer-start!` follows and because it stops
  being free the moment anything (a threaded build, or a future verb that
  pumps the loop) makes the window real.
- **A shutdown request's `free!` has no counter.** Design spec §10 enumerates
  six counter classes and a shutdown request is not one of them, so
  `shutdown-dispatch` deliberately passes a no-op counter. The REGISTRY
  stands in — "the shutdown request was already deregistered when
  on-shutdown ran" and the registry-balance rows would both catch a
  dispatcher that stopped popping — but a shutdown block that was
  deregistered and *not* freed would be invisible to every assertion in this
  repo. Valgrind on Linux (ADR-0003) is the only gate that covers it.
- **Mutation 13's coverage is platform-dependent.** `abandon-request!` runs
  only when a native call fails *synchronously*, and the row that reaches it
  is the write-after-shutdown one, which on this platform refuses
  synchronously with `EPIPE` (recorded below). On a platform where `uv_write`
  accepts that write and reports the failure to the completion callback
  instead, nothing in the suite would exercise `abandon-request!` at all and
  mutation 13 would survive. The suite asserts the disjunction deliberately
  (either failure is legal); this note is what stops the coverage claim from
  travelling further than the platform it was measured on.

## Platform behaviours measured, not assumed

Recorded because the suites assert a *disjunction* where libuv makes no
promise, and because a later reader deserves to know which arm ran here
(macOS 25.5.0, arm64, libuv 1.52.1):

| Situation | Observed here |
|---|---|
| `uv-write!` after a completed `uv-shutdown!` | **synchronous** raise, errno `EPIPE`; no completion callback is ever scheduled |
| A 5-byte write racing `uv-close!` | completes with **no error** — the kernel already had the bytes |
| A 4 MiB write racing `uv-close!` | completes with `'ECANCELED`, delivered to a handle already in state `'closing` (this is the row that actually exercises design spec §5's tolerance rule) |
| `uv-accept!` with nothing queued | `EAGAIN` |
| `uv-tcp-getsockname-port` on a handle that was never bound | `EBADF` (no fd exists yet on unix) |
| Connect to a loopback port whose listener was fully closed | `'ECONNREFUSED` |

## Notes on individual mutations

**Mutation 1 (free before `uv_write`) — recorded as process death, not as a
failed assertion.** The brief anticipated "ASan/valgrind red or completion
test fails — record which". Neither: on this platform the plain, un-ASan'd
run dies outright (`exit -5` / `exit -6`, SIGTRAP and SIGABRT from the system
allocator) as libuv walks a freed `uv_write_t`. That is louder than a failing
assertion and needs no sanitizer, but it is worth naming for what it is — the
suites did not *catch* this mutation, the allocator did. The assertions that
would have caught it are the counter-balance rows, and they never got to run.

**Mutation 2 shows why the registry pop must precede reuse.** The failure is
not "a callback was delivered twice"; it is `pointer-already-registered`,
raised by a *later* `foreign-alloc` handing back the same address while the
stale entry is still in the table. That is precisely the double-free-shaped
defect the duplicate check exists to report, arriving through the documented
channel.

**Mutation 19 is a TIMEOUT rather than a named failure, and that is the
honest result.** An unregistered connect request means the connect dispatcher
resolves nothing, records an orphan, and never runs the caller's callback —
so every suite that waits for a connect blocks in `uv-run 'default`. The
180 s cap turns that into a recorded `TIMEOUT`. The named-assertion detector
for the same decision is `test-tcp.sps`'s "the in-flight write request is
registered against its handle's loop", which covers the write request's
registration directly.


## Verification runs behind this log

All on macOS 25.5.0 / arm64, Chez 10.4.1, libuv 1.52.1, dev shim
(`CFLAGS_DEV`, `-DCHEZ_LIBUV_DEBUG_COUNTERS`):

| Run | Result |
|---|---|
| `make test` (pkg-config leg) ×2 | ALL SUITES PASSED, exit 0 both times — 706 assertions |
| `make HAVE_PKG=no test` (vendored leg) ×2 | ALL SUITES PASSED, exit 0 both times — same 706 |
| `make check-purity` | green — `test-conditions.sps` pulled in no native code with `CHEZ_LIBUV_SHIM` poisoned |
| `make check-pins`, `make check-help` | green (pins agree, vendored libuv 1.52.1 in range, README floor stated) |
| `make test-memory` (macOS ASan preload) | exit 0, every suite passed, **no sanitizer diagnostic**. Not a leak claim: LeakSanitizer is unsupported on arm64 and ADR-0003 makes Linux Valgrind the sole memory gate. What this run does show is that the write path's frees — one block per write, freed once, in the dispatcher — produce no use-after-free or double-free that ASan can see, including on the 4 MiB cancelled write. |

Per-suite assertion counts, identical across all four `make test` runs:
`conditions` 89, `facade` 37, `lifecycle` 60, `loop` 106, `native` 170,
`shim-loading` 19, `tcp` 93, `timer` 132.
