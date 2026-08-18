# Stage 5 Mutation Log

Task 9 opens this log. It covers the TCP **read** path — `uv-read-start!` /
`uv-read-stop!` and the per-handle buffer in `src/libuv/tcp.sls`, the alloc
and read dispatchers in `src/libuv/private/handles.sls`, the `uv_read_start` /
`uv_read_stop` bindings and the alloc/read trampoline pairing in
`src/libuv/private/native.sls`, the `getsockname` namelen check that gives
`c-int-ref` its first production use, and the `(libuv)` facade's two new
re-exports — proving that every decision those files encode has an assertion
in `tests/test-tcp.sps`, `tests/test-timer.sps` or `tests/test-facade.sps`
that fails, **by name**, when the decision is broken.

## Red before green

The suites were written first and run against the tree with no read path in
it. `…/scratchpad/stage5-red-run.txt` is that run:

```
=== tests/test-facade.sps ===
Exception: attempt to reference unbound identifier uv-read-start! at line 276
=== tests/test-tcp.sps ===
Exception: attempt to reference unbound identifier uv-read-start! at line 728
=== tests/test-timer.sps ===
FAIL replacing a dispatcher a later stage installed is refused, naming who and why
FAIL the refused replacement left the real read dispatcher in place
# of expected passes      126
# of unexpected failures  2
SUITE FAILED
```

The two timer rows are genuine per-assertion red evidence: they are the
rewritten seam rows, and against a tree where `'read` is still Stage 3's stub
`install-dispatch-procedure!` *succeeds* instead of refusing. The tcp and
facade suites could not run at all in that state, which is honest evidence of
ordering and nothing more — the per-assertion evidence for those two suites is
the mutation table below.

Two things were added to the suites *after* that run and are therefore not in
it: the row pinning the observed reset errno (written once the shape row had
been driven and the value measured), and the `run-until/ticking` fixture,
which came out of the first mutation pass. Both are covered by the table.

## Method

Identical to `.plans/stage-{1,2,3,4}-mutation-log.md`, and to AGENTS.md's "a
test is not finished when it passes; it is finished when you have watched it
fail":

1. The three files under test were copied, once, to a scratch tree *outside*
   this repository —
   `…/scratchpad/stage5/mutation-scratch/src/{libuv/tcp.sls,libuv/private/{handles,native}.sls}`
   — each with a `.pristine` sibling. The repo's own files were never edited
   during mutation testing.
2. Each mutation edits *only* the scratch copy, breaking exactly one
   decision. The driver refuses to apply an edit whose anchor text is not
   unique in the file, so no mutation can land somewhere other than where it
   was aimed.
3. The six loop-driving suites run from the repo, unmutated, against the
   mutated library:

   ```
   CHEZSCHEMELIBDIRS="$SCRATCH/src:$REPO/src:$REPO/tests:$REPO/build/scheme-libs" \
     chez --program $REPO/tests/test-tcp.sps
   ```

4. Failing test names are recorded verbatim with the process exit status. A
   180 s per-suite cap turns a mutation that blocks into a recorded
   `TIMEOUT` rather than a stuck run.
5. The scratch copy is restored from `.pristine` and all six suites are re-run
   to confirm green before the next mutation.

Driver, mutation set and raw output:
`…/scratchpad/stage5/{mutate5.py,mutations5.json,mutations-run-final.txt,results5.json}`.

**Baseline** (before any mutation, and reconfirmed green after every one):

| Suite | Assertions | Exit |
|---|---|---|
| `tests/test-tcp.sps` | 166 | 0 |
| `tests/test-timer.sps` | 128 | 0 |
| `tests/test-native.sps` | 170 | 0 |
| `tests/test-loop.sps` | 106 | 0 |
| `tests/test-lifecycle.sps` | 60 | 0 |
| `tests/test-facade.sps` | 40 | 0 |
| `tests/test-conditions.sps` (not in the driver's set) | 89 | 0 |
| `tests/test-shim-loading.sps` (not in the driver's set) | 19 | 0 |

The set was run **twice in full**. The first pass produced four `TIMEOUT`s;
they were answered by a change to the test fixture rather than written off
(see "What the first pass changed"), and the whole set was re-run. **The table
reports the second pass**; the first pass is kept alongside it as
`mutations-run-pass1.txt`.

## Summary

Failing test names are quoted verbatim from the SRFI-64 runner. Where a
mutation produced a cascade, the **first** name listed is the one that names
the broken decision; the rest are consequences. Every mutation was confirmed
**restored-green** before the next was applied.

| # | Decision under test | Mutation | Result | Named test(s) that failed |
|---|---|---|---|---|
| 1 | ONE reusable buffer per handle, allocated by the first start (design spec §6) | `ensure-read-buffer!` allocates on every start | FAIL, exit 1 | "50 read-start/stop cycles leave exactly one live read buffer"; "...and it is the same buffer, not a fresh allocation per call"; "seed: a second reading handle means a second read buffer" (+5 more) |
| 2 | The delivery is a COPY, made at the boundary (ADR-0009) | the foreign pointer is handed to `on-data` in place of the bytevector | **exit 255**, both loop suites | `Exception in bytevector-length: 42790289408 is not a bytevector` — the suite dies naming the type it was handed; see the note below |
| 3 | `UV_EOF` is its own callback, never an error (design spec §6) | the EOF arm calls `deliver-read-error!` | FAIL, exit 1 | "the peer's on-eof fired when the client shut its write side down"; "the end of the stream fired on-eof exactly once"; "EOF is delivered as on-eof, never as an error" (+3 more) |
| 4 | `UV_EOF` comes from the shim's table, never transcribed (ADR-0005) | `(= nread (uv-eof))` → `(= nread -4095)` | **NOT CAUGHT** — passes everywhere, by construction | none; see "Uncovered, and why" |
| 5 | `uv-read-stop!` clears the handle's reading flag | the `set-tcp-reading!` dropped | FAIL, exit 1 | "uv-read-stop! outside a callback clears the reading flag"; "the first chunk arrived, and on-data stopped the read from inside itself" |
| 6 | The delivered span starts at 0 | `(on-data bv 1 nread)` | FAIL, exit 1 | "on-data is handed the span (0 . nread) over a bytevector of exactly nread bytes"; "the bytes the peer read are the bytes the client wrote"; "every on-data span covered its whole bytevector, start 0 and end nread" (+6 more, incl. the facade row) |
| 7 | The delivered span ends at nread | `(on-data bv 0 (- nread 1))` | FAIL, exit 1 | same three rows, plus "a 1 MiB transfer in 64 KiB chunks arrives byte for byte" |
| 8 | `nread = 0` is "nothing to read this time", never data (design spec §6) | the zero arm falls into `deliver-read-data!` | FAIL, exit 1 | "a read callback with nread = 0 delivers nothing: not data, not EOF, not an error"; "...and reaches neither on-data nor on-eof"; "no on-data delivery in this section had an empty span" |
| 9 | `alloc_cb` answers the buffer's REAL length, not libuv's hint | `(uv-buf-set! buf base suggested)` | FAIL, exit 1 | "the alloc dispatcher hands libuv the handle's own buffer, at its full length" — and *only* that one |
| 10 | `alloc_cb` writes base and len into the right fields | the two arguments swapped | FAIL + **exit 255** | "the peer's on-data callback delivered the client's write" (+3), then `Exception in uv-read-start!: socket is not connected` — libuv reads into address 65536 and the socket dies |
| 11 | A handle it cannot serve gets an EMPTY buffer, not an untouched one | the `(uv-buf-set! buf 0 0)` arm becomes a no-op | FAIL, exit 1 | "...and answers the EMPTY buffer libuv turns into UV_ENOBUFS"; "a tcp handle that never started reading gets the empty buffer too" |
| 12 | The buffer's size is FIXED by the first start | the `'buffer-size-fixed` raise dropped | FAIL, exit 1 | "restarting with a DIFFERENT explicit buffer size is refused, naming who and why"; "restarting with the size OMITTED reuses the buffer at whatever size it was fixed" |
| 13 | An OMITTED size is not the same question as an explicit default | the 4-argument clause passes `default-read-buffer-size` instead of `#f` | FAIL, exit 1 | "restarting with the size OMITTED reuses the buffer at whatever size it was fixed" — and *only* that one |
| 14 | The read dispatcher tolerates a `'closing` handle (design spec §5) | an `(eq? (handle-state handle) 'open)` check added | FAIL, exit 1 | "a read callback that raced a close is still delivered ('closing is tolerated)" — and *only* that one |
| 15 | A read callback for an unregistered pointer is RECORDED, not swallowed | the `record-orphan-callback!` arm becomes `#f` | FAIL, exit 1 | "...and is recorded as an orphan naming its callback type and pointer"; "the refused replacement left the real read dispatcher in place" (`test-timer`) |
| 16 | The namelen check accepts a real sockaddr | threshold raised to `sizeof(sockaddr_storage)` | **exit 255** ×3 | no assertion — `(define bound-port (uv-tcp-getsockname-port t0))` runs at suite top level and raises before any row; see the note below |
| 17 | ...and is not written as an equality against IPv4's size | `(= (c-int-ref len) (sizeof-sockaddr-in))` | FAIL, exit 1 | "uv-tcp-getsockname-port answers for an IPv6 handle too, whose namelen differs" — and *only* that one |
| 18 | The namelen is read back at all | the whole check deleted | **NOT CAUGHT** — the refusal arm is unreachable through this API | none; see "Uncovered, and why" |
| 19 | `uv-read-start!` records that the handle is reading | the `set-tcp-reading!` dropped | FAIL, exit 1 | "a started read records that the handle is reading" — and *only* that one |
| 20 | `uv_read_start` gets the alloc and read entry points in that order | the two swapped | FAIL + exit 255 | "on-data is handed the span (0 . nread)…"; "the bytes the peer read are the bytes the client wrote"; "a 1 MiB transfer in 64 KiB chunks arrives byte for byte" (+6, incl. the facade row) |
| 21 | `uv-read-stop!` actually calls `uv_read_stop` | the native call dropped, the flag still cleared | **exit 255** | `Exception in uv-read-start!: connection already in progress` — the 50-cycle row's second start hits `EALREADY`; the suite dies naming `uv-read-start!` |
| 22 | `'read` is installed through the seam, by name | `(cons 'read read-dispatch)` dropped from the install list | exit 255 ×2, FAIL ×2 | `Exception in read: this callback type is not implemented in this version`; "replacing a dispatcher a later stage installed is refused, naming who and why" (`test-timer`) |
| 23 | The callbacks are stored AFTER a successful `uv_read_start` | the three stores moved ahead of it | **NOT CAUGHT** — unobservable single-threaded | none; see "Uncovered, and why" |
| 24 | The buffer size is validated BEFORE anything is allocated | the check moved after `ensure-read-buffer!` | FAIL, exit 1 | "a buffer size of zero is refused before anything is allocated"; "an inexact buffer size is refused, naming who and why"; "a negative buffer size is refused, naming who and why" |

## What the first pass changed

The first pass ran against the suites as first written, and mutations 3, 6, 7
and 10 came back as `TIMEOUT` rather than as named failures — a real
detection, but one that names nothing, which is exactly the complaint Stage
4's log records against its own mutation 19.

The cause was in the fixture, not in the assertions. `uv-run loop 'once`
**blocks** until the loop's next due event. That is what makes a 1 ms timer
test deterministic, but it also means a predicate that never holds — precisely
what a broken delivery path produces — leaves the *first* step blocked in the
kernel, where `run-until`'s iteration cap never gets to count. Design spec
§11's "failure is iteration exhaustion, never wall-clock elapsed time" was
true of the cap and false of the loop underneath it.

`tests/uv-testing.sls` now also provides **`run-until/ticking`**: the same
drain with a 1 ms repeating timer armed for its duration (closed, and its
close drained, before it returns, so a caller can go straight from it to a
debug-counter assertion). Every wait in the read suites whose predicate
depends on a callback being delivered uses it. On the second pass mutations 3,
6 and 7 fail **by name**, and 10 fails by name in `test-tcp` before the socket
dies.

`test-facade.sps` deliberately does not use `uv-testing` (nothing may stand
between that suite and the facade), so its own drain still has the old shape
and still shows as a `TIMEOUT` under mutation 10. That is acceptable
precisely because it is not the detector of record for anything: every
mutation is caught by name in `test-tcp` first.

> **Addendum (Task 10, Stage 6).** `run-until/ticking` as written above
> disarmed its ticker only on the path where the wait **returned**. A wait
> ended by a raise — which is every wait whose callback under test raised,
> since uv-run's store-and-reraise policy turns that into an
> `&uv-callback-error` out of the very `uv-run` this fixture drives — left the
> 1 ms timer armed on the loop, and every assertion after it measured a loop
> the fixture was still holding open. It is now unwind-safe: the disarm runs
> on both paths, guarded on the unwind path only (a condition raised while
> unwinding would replace the callback error the caller is trying to see) and
> deliberately unguarded on the normal one. `tests/test-lifecycle.sps` gained
> the row that watches it — **"the ticking fixture disarmed its own timer on
> the unwind path"**, which reads 2 instead of 1 against the pre-fix fixture
> (`.plans/stage-6-mutation-log.md`, mutation 11). Nothing above this line was
> rewritten; this is the only change to the Stage 5 record.

## Uncovered, and why

- **Mutation 4 — the `UV_EOF` literal is an equivalent mutant, everywhere.**
  `UV_EOF` is `-4095` on every platform libuv supports; it is a libuv-defined
  sentinel rather than a system errno (spike `FINDINGS.md`, Q3: "a
  libuv-defined sentinel, identical across platforms"). So
  `(= nread -4095)` and `(= nread (uv-eof))` cannot be told apart by any test
  that can be written here, and none is claimed. The constant is still looked
  up, because ADR-0005 is a rule about *where values come from*, not about
  which values happen to differ per platform — and the rule does have an
  executable guard: ADR-0005's own shim-deletion mutation
  (`.plans/stage-1-mutation-log.md`, the `UV_EOF` row removed from the shim's
  constant table) makes every suite that reaches this code fail closed with
  `&uv-constant-unavailable` naming `UV_EOF`, which a transcribed literal
  would sail straight past. That mutation is this decision's detector; this
  one is recorded as uncatchable on its own terms, per AGENTS.md.
- **Mutation 18 — the namelen check's refusal arm is unreachable through this
  API.** `uv-tcp-getsockname-port` seeds the out-parameter with
  `sizeof(sockaddr_storage)` (128 here) and libuv writes back 16 for
  `sockaddr_in` or 28 for `sockaddr_in6`; both are far above the 4 bytes the
  port's decode needs, on both supported platforms, so nothing a caller can do
  makes the check fire. What IS covered is the other direction — that the
  check is not written so strictly that a real address is refused — by two
  rows at two different real namelens (mutations 16 and 17 above; 17 fails by
  name at IPv6's 28). The check is kept because the failure it guards against
  is silent: a short `namelen` would be decoded out of the zeroed tail of the
  scratch and returned as **port 0**, which is in range, plausible, and wrong
  — the same failure shape as the byte-order bug that mutation 6 of Stage 4
  covers. Recorded rather than deleted.
- **Mutation 23 — the callback-store ordering is unobservable
  single-threaded.** Same shape as Stage 4's mutation 17, and the same
  reasoning: nothing runs the loop between `uv_read_start` returning and the
  next Scheme statement, so "stored before" and "stored after" are
  indistinguishable in this binding as it exists. The ordering is kept because
  it is what makes a *refused* start (`EALREADY` on a handle that is already
  reading) leave the running read's callbacks alone, and that becomes
  observable the moment anything makes the window real.
- **The "fresh copy per delivery" claim has no single-line mutant.** ADR-0009
  says every `on-data` delivery is a bytevector of its own; a binding that
  cached one scratch bytevector per handle and refilled it would be a *new*
  mechanism, not an edit to an existing decision, so no mutation in this set
  expresses it. What stands in for one is the shape of the fixture:
  `make-byte-collector` deliberately **keeps the caller's bytevectors rather
  than copying them**, so the byte-for-byte comparison at the end of the 1 MiB
  transfer is also the assertion that the sixteen deliveries were sixteen
  objects. A shared scratch would show up there as a megabyte of the last
  chunk repeated.
- **The seam guard's ORPHAN fork lost its detector this stage, and did not get
  a new one.** While `'alloc` and `'read` were raising stubs, firing one on an
  unregistered pointer proved that `contain-dispatcher-raise!` records an
  orphan when there is no loop to record against (`test-timer.sps`, Stage 3).
  With every name now holding a real dispatcher, a raise *requires* a
  successful registry lookup — every dispatcher looks the pointer up before it
  can do anything that raises — so the "raised, and the pointer is not
  registered" arm is no longer reachable through installed code. The rewritten
  rows cover the REGISTERED fork (a request record whose `handle` field is not
  a handle: the accessor raises inside `complete-request!`, outside every
  `dispatch-guarded`, and the object surfaces from `uv-run` as
  `&uv-callback-error` carrying the original assertion). Deleting the orphan
  arm of `contain-dispatcher-raise!` would now pass every suite. It is kept as
  a last-resort bug reporter for exactly the situation nothing else can
  describe, and this note is the record that it is currently unguarded.

## Platform behaviours measured, not assumed

Recorded because the suites assert against values the kernel chooses, and
because a later reader deserves to know which arm ran here (macOS 25.5.0,
arm64, libuv 1.52.1):

| Situation | Observed here |
|---|---|
| A socket closed with unread data in its receive queue, from the reader's side | `'ECONNRESET`, delivered to `on-error`; `on-eof` fired 0 times and `on-data` 0 times |
| `uv-read-start!` on a handle that was never connected | `'ENOTCONN` |
| `uv-read-start!` on a handle that is already reading | `'EALREADY` |
| `uv-read-stop!` on a handle that is not reading | rc 0 — idempotent at the libuv level, no state test needed on the Scheme side |
| `uv_tcp_getsockname`'s namelen | 16 for an IPv4 handle, 28 for an IPv6 one |
| libuv's `suggested_size` to `alloc_cb` | 64 KiB (`vendor/libuv/src/unix/stream.c`), which is also this binding's default buffer size — ignored either way |

**The `'ECONNRESET` row is the one that could vary.** The provocation is the
abortive close of RFC 1122 §4.2.2.13 (close a socket whose receive queue is
not empty and the stack must send RST), which both Darwin and Linux implement,
and it reproduced on every run here. `tests/test-tcp.sps` therefore asserts it
in two rows deliberately split: the **shape** row ("delivered to on-error as a
symbol errno, and not to on-eof") is the contract this binding owns, and the
**value** row ("the errno an abortive close produces here is 'ECONNRESET") is
the kernel's answer, marked in the file as the row to re-measure if a platform
ever disagrees.

## Notes on individual mutations

**Mutation 2 (no copy-out) — recorded as process death, not as a failed
assertion.** Handing `on-data` the raw `uptr` makes the first thing any real
caller does — ask for the bytevector's length or copy out of it — fail with a
Chez type error carrying the pointer value. That is louder than a failing
assertion and it names the type confusion exactly, but it is worth being
precise about what caught it: the *suite* did not catch this one, Chez did.
The assertion that would have caught it is "the bytes the peer read are the
bytes the client wrote", and it never got to run.

**Mutation 16 (namelen threshold raised) — also process death, and for a
structural reason.** `tests/test-tcp.sps` reads the ephemeral port back at
suite top level (`(define bound-port (uv-tcp-getsockname-port t0))`), so a
`uv-tcp-getsockname-port` that refuses every real address raises before the
first row runs. The by-name detector for the same decision is mutation 17,
whose threshold refuses only IPv6 and therefore leaves the suite standing long
enough to fail the row that was written for it.

**Mutation 21 (read-stop that does not stop) — caught by an escaping errno,
not by the backpressure row.** The backpressure section is the assertion that
*means* something here ("a stopped reader receives nothing, however long the
loop runs"), but the 50-cycle buffer-reuse rows run earlier and their second
`uv-read-start!` hits `EALREADY` first, killing the suite with a condition
that names `uv-read-start!`. Both detections are real; the order of the file
decides which one is seen.

## Verification runs behind this log

All on macOS 25.5.0 / arm64, Chez 10.4.1, libuv 1.52.1, dev shim
(`CFLAGS_DEV`, `-DCHEZ_LIBUV_DEBUG_COUNTERS`):

| Run | Result |
|---|---|
| `make test` (pkg-config leg) ×2 | ALL SUITES PASSED, exit 0 both times — 778 assertions |
| `make HAVE_PKG=no test` (vendored leg) ×2 | ALL SUITES PASSED, exit 0 both times — same 778 |
| `make check-purity` | green — `test-conditions.sps` pulled in no native code with `CHEZ_LIBUV_SHIM` poisoned |
| `make check-pins`, `make check-help` | green |
| `make test-memory` (macOS ASan preload) | exit 0, every suite passed, **no sanitizer diagnostic**. Not a leak claim: LeakSanitizer is unsupported on arm64 and ADR-0003 makes Linux Valgrind the sole memory gate. What it does show is that this stage's hotspot — a megabyte of copy-out churn through one reused 64 KiB buffer, plus 50 start/stop cycles and two more buffers freed by the close dispatcher — produces no use-after-free or double-free that ASan can see. |

Per-suite assertion counts, identical across all four `make test` runs:
`conditions` 89, `facade` 40, `lifecycle` 60, `loop` 106, `native` 170,
`shim-loading` 19, `tcp` 166, `timer` 128.

## Post-v0.1 cleanup round (chore/post-v0.1-cleanup)

**`reading?` semantics decided and locked in.** The final review flagged the
flag as stale after EOF/error (Task 9 deferred Minors: "bookkeeping drift,
no production reader"). Decision: it records CALLER INTENT -- a successful
`uv-read-start!` not yet followed by `uv-read-stop!` -- not libuv's live
read state, which would need per-arm knowledge of stream.c that varies
across the supported 1.x range (libuv clears UV_HANDLE_READING on EOF
itself, stops the watcher on errors). The EOF and error dispatchers
deliberately leave it set; the record comment in handles.sls now says so,
and one test-tcp row locks it in at the point where the handle has been
delivered BOTH a real EOF and an error. Mutation-watched (scratch copy,
restored-green diff-identical):

| Target | Mutation | Result | Named test(s) that failed |
|---|---|---|---|
| handles.sls | `deliver-read-eof!` clears the flag (`set-tcp-reading! handle #f` ahead of delivery) — the rejected "mirror libuv" semantics | FAIL, exit 1 — the ONLY failure (167 other rows passed) | "reading? is caller intent: it survives EOF and error delivery until uv-read-stop!" |
