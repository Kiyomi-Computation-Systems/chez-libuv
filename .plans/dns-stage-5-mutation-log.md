# DNS Stage 5 Mutation Log

Covers the Stage 5 delta in `src/libuv/dns.sls` — `uv-getnameinfo!` (both
arities, the TCP input vocabulary, the nameinfo flags mapper, the
co-allocated `[uv_getnameinfo_t | pad16 | sockaddr_storage]` start call),
the getnameinfo dispatcher (copy-before-free, orphan and kind-mismatch
arms), and `uv-cancel!` (domain check, zeroed-ptr guard, rc policy) — plus
the one Stage 3 machinery decision this stage's tests were chartered to
catch (`cancel-requests-for-loop!`'s kind filter, the Stage 3 M3 caveat)
and the `complete-request!` free-before-delivery order now guarded for both
DNS kinds. Owning suite: `tests/test-dns.sps` (121 passes at this stage's
baseline; 77 at Stage 4's).

## Red before green

The Stage 5 rows were written first and run against the Stage 4 tree
(HEAD `451abaa`, no getnameinfo/cancel surface). That run is
`stage5-red-run.txt` (session scratchpad):

```
Exception: attempt to reference unbound identifier uv-getnameinfo! at line 843, char 2 of tests/test-dns.sps
```

exit 255. This is honest evidence of ordering and nothing more — the
per-assertion red evidence is the mutation table below, exactly as the
v0.1 stage-5 log put it for its own unbound-identifier red run.

## The race that rewrote two rows mid-stage (recorded, not hidden)

The queued-tail teardown row was first written in the brief's shape — ONE
numeric blocker + the getnameinfo tail, teardown in the same turn, the
tail's `'EAI_CANCELED` asserted as a single-shot forced branch. That shape
FAILED a real `make test-memory` run (macOS ASan arm):

```
FAIL queued-tail teardown: the queued tail was cancelled -- EAI_CANCELED, host/service #f
# of expected passes      121
# of unexpected failures  1
```

Diagnosis (probe script, session scratchpad, all runs under the recipe's
exact ASan env, pool pinned to 1, teardown-in-same-turn shape, N trials
each):

| shape | cancelled / trials |
|---|---|
| 4 blockers, no collect discipline | 100 / 100 |
| 4 blockers, forced `(collect)` INSIDE the submit-to-sweep window | 48 / 100 |
| 4 blockers, `(collect)` BEFORE the submits | 495 / 500 |
| 32 blockers, `(collect)` BEFORE the submits | 475 / 500 |

So "pool=1 guarantees the tail is queued" holds only while the worker is
still behind the blockers: a GC pause landing inside the submit-to-sweep
window lets the single worker drain any queue depth (the forced-collect
row is the smoking gun — half the trials lost), and a ~1% residual loss
survives even with the collect hoisted (scheduler pauses; more blockers
made it WORSE, not better, by lengthening the exposed submit loop). Q3's
1000/1000 licensed the branch's heavy favorite, and its own "What this
does NOT show" section warned that a suite must not rely on
submit-then-cancel timing for the completed branch — the same physics,
mirrored.

The fix keeps the branch FORCED rather than weakening it to the spec §9
tolerant shape: each attempt `(collect)`s first (no organic pause in the
window), and the scenario retries — bounded by attempts, never wall-clock
— until the cancel-won branch is observed (max 16; measured p(loss) ≈ 1%
per attempt → vanishing). The branch-independent invariants (loop closed,
all five callbacks exactly once before teardown returned, blockers in
legal branches, counters/registry balanced) are asserted over EVERY
attempt, losing draws included. Under the kind-narrow mutation the branch
can NEVER be observed, so the catcher row fails deterministically — M3
below watched exactly that. The double-cancel row's forced first-`#t` has
the same physics and got the same bounded-retry shape. After the rework:
three consecutive full `make test-memory` runs green, every attempt
winning on attempt 1.

## Method

Identical to `.plans/stage-{1..6}-mutation-log.md` and AGENTS.md's "a test
is not finished when it passes; it is finished when you have watched it
fail":

1. The two files under test were copied once to a scratch tree OUTSIDE the
   repository (session scratchpad,
   `stage5-mutation/src/libuv/{dns.sls,private/handles.sls}`), each with a
   `.pristine` sibling. The repo's own files were never edited during
   mutation testing.
2. Each mutation edits only the scratch copy, breaking exactly one
   decision, applied by a driver that refuses any anchor text not unique
   in the file.
3. The suite runs from the repo, unmutated, against the mutated tree:
   `CHEZSCHEMELIBDIRS="$SCRATCH/src:src:tests:build/scheme-libs" chez
   --program tests/test-dns.sps`.
4. Failing test names recorded verbatim with the exit status.
5. The scratch copy is restored from `.pristine` and the suite re-run
   green before the next mutation (verified after every round, including
   the last).

**Baseline** (pristine scratch tree, before the first mutation):
121 passes, exit 0.

M5 is the one suite-side sanity mutation (per the stage brief, run once):
it edits a scratch COPY of `tests/test-dns.sps` and runs it against the
pristine library.

## Mutation log

| # | Anchor edited | Mutation | Verbatim first named failure(s) |
|---|---|---|---|
| M1 | src/libuv/dns.sls | getnameinfo dispatcher extras order swapped (`status service hostname`) | `FAIL reverse v4: hostname is the literal rendered back` + `FAIL reverse v4: service is the port as a decimal STRING` + both v6 twins + `FAIL close with in-flight request: the drained lookup delivered normally` — "8080" where "127.0.0.1" expected, exactly as chartered; exit 1, 5 failures |
| M2 | src/libuv/dns.sls | copy-before-free dropped: the two `c-string->string` copies moved to AFTER `complete-request!` frees the block (delivered through a wrapper closure reading the freed block) | Plain build: `FAIL reverse v4: hostname is the literal rendered back` + the other 3 reverse rows — fails BY NAME even unsanitized (the freed block's contents are already clobbered by delivery time). ASan arm: **121 passes, exit 0 — BLIND**: DYLD-inserted ASan on an uninstrumented binary performs interceptor-level checks only (no load/store shadow checks), and its quarantine keeps the stale contents intact. Addressability backstop **OBSERVED** on the Linux valgrind leg, CI run 32509190939 (2026-08-21): `Invalid read of size 1` into `a block of size 1,456 free'd`, `ERROR SUMMARY: 100 errors from 1 contexts`, `make: *** [Makefile:426: test-memory] Error 1`, step-observed exit 2 — and the suite stayed GREEN under Memcheck (`# of expected passes      121`; the by-name failures are the plain build's record, not this leg's). Full verbatim record in "Linux valgrind observation" below. |
| M3 | src/libuv/private/handles.sls | `cancel-requests-for-loop!` kind filter narrowed to `'(getaddrinfo-req)` (the Stage 3 M3 caveat's named catcher) | `[informational] queued-tail teardown: cancel won on attempt 16 of max 16` then `FAIL queued-tail teardown: the sweep cancelled the queued tail within the attempt bound` + `FAIL queued-tail teardown: the cancelled tail delivered EAI_CANCELED with host and service #f`. Measured behavior under the mutation, verbatim from the run: the sweep never reaches the tail on ANY of the 16 attempts; the drain waits the tail's REAL result out each time (teardown still returns, all five callbacks still fire exactly once, counters/registry still balance — the invariants row PASSED), so only the branch-observation rows fail, deterministically. |
| M4 | src/libuv/dns.sls | `uv-cancel!`'s zeroed-ptr check skipped (`(if #f #f ...)` — native call made on the stale pointer) | `FAIL cancel after completion: answers #f, and nothing raises`. Actual behavior, probed: `uv_cancel(0)` reads `req->type` through the NULL pointer and Chez converts the fault into a raised `invalid memory reference` condition — the row's guard catches it and the row fails by name with `(raised ... invalid memory reference ...)`, no process death. (The zeroing at the freeing site is what makes the stale-pointer case the NULL case; a reused-address UAF remains valgrind territory.) |
| M5 | tests/test-dns.sps (suite copy, run once) | tolerant row's cancel-won arm asserts `'ECANCELED` instead of `'EAI_CANCELED` | `FAIL tolerant cancel: the branch taken carries its paired consequence` — the cancel won on that run and delivered the rewritten `'EAI_CANCELED`, exactly the one-spelling contract (getaddrinfo.c:128-133) |
| M6 | src/libuv/dns.sls | `uv-cancel!` domain check widened to `uv-req?` (kind check dropped) | `FAIL uv-cancel! refuses a v0.1-kind request record, by kind` — only row; the non-record row still passes through the widened check |
| M7 | src/libuv/dns.sls | getnameinfo dispatcher kind-mismatch clause made unreachable | `FAIL getnameinfo kind-mismatch arm: contained, and re-raised from uv-run by name` + `FAIL epilogue: exactly the two deliberate orphan events, no strays` (the wrong-kind entry fell through to `complete-request!`'s orphan arm — Stage 4 M18's shape on the second dispatcher) |
| M8 | src/libuv/dns.sls | getnameinfo orphan arm records nothing | `FAIL getnameinfo orphan arm: the event is recorded with the dispatcher's name and pointer` + the orphan-count epilogue |
| M9 | src/libuv/dns.sls | dispatcher freeing-site counter replaced with a no-op | `FAIL getnameinfo in flight: the live counter reads 1 after submit, before stepping` (the earlier reverse rows never decremented) + the freed-before row + every balance row — 7 failures |
| M10 | src/libuv/dns.sls | registration-site `count-getnameinfo-req-new!` dropped | Same 7 rows, first named: `FAIL getnameinfo in flight: the live counter reads 1 after submit, before stepping` (reads 0; later balances go negative) |
| M11 | src/libuv/dns.sls | nameinfo flags mapper's else arm contributes 0 instead of raising | `FAIL boundary: a flag outside the closed nameinfo set is refused` + `FAIL boundary: every rejection above allocated and registered nothing` + the teardown invariants row — the mutated call REALLY submitted a live request, exactly Stage 4 M9's confirming pattern |
| M12 | src/libuv/dns.sls | pre-registration guard's `free!` dropped (garbage-address path leaks the block) | **121 passes, exit 0 — SUITE-BLIND, as predicted**: the block was never registered or counted, so no counter/registry row can see it, and the macOS ASan arm runs `detect_leaks=0`. **GATE-CAUGHT — OBSERVED** on the Linux valgrind leg, CI run 32509190939 (2026-08-21): suite green under the mutation (121 passes) while the gate fired — `1,456 bytes in 1 blocks are definitely lost`, alloc'd at Chez's `s_malloc` (the co-allocated request block, leaked whole), `definitely lost: 1,456 bytes in 1 blocks`, `make: *** [Makefile:426: test-memory] Error 1`, step-observed exit 2. Full verbatim record in "Linux valgrind observation" below. |
| M13 | src/libuv/private/handles.sls | `complete-request!` delivers BEFORE deregister/free/count/zero | `FAIL freed before on-complete: the live counter reads 0 inside the callback` + ptr-zeroed + registry-popped (the Stage 4 M4 triplet) **and** the same three `getnameinfo freed before on-complete: ...` rows — 6 failures, both kinds' lifecycle triplets through the one shared code path |
| M14 | src/libuv/dns.sls | `require-address` dropped | `FAIL boundary: a non-string address is refused` — the integer address reaches `fill-sockaddr!`'s FFI string parameter and raises a non-`&uv-invalid-argument`; the rejection helper answers `wrong-condition` |
| M15 | src/libuv/dns.sls | `require-port` dropped | `FAIL boundary: an out-of-range port is refused` + the allocated-nothing balance row + the teardown invariants row — port 65536 truncates in `htons` and the mutated call really submits (port 0), the same really-submitted pattern as M11 |
| M16 | src/libuv/dns.sls | non-list flags check dropped | `FAIL boundary: a non-list flags argument is refused` — `fold-left` over the bare symbol raises a non-`&uv-invalid-argument`; helper answers `wrong-condition` |

Every round restored from `.pristine` and re-verified green (121 passes,
exit 0) before the next; final restore re-verified after M16; the scratch
tree was deleted after the round.

## Honest uncovered / gate-only records

- **getnameinfo's post-registration abandon guard — UNREACHABLE BY
  CONSTRUCTION, kept.** Both `UV_EINVAL` paths precede `uv__req_init`
  (`vendor/libuv/src/unix/getnameinfo.c:86-98` vs `:101`), and with a
  non-NULL callback the call returns 0 unconditionally (`:109-115`) — so
  no input can drive the guard, and a mutation deleting it changes no
  observable behavior. Recorded raising-through per the house convention
  (tcp.sls:150-156 precedent), in the start call's own comment; contrast
  getaddrinfo's guard, which the idna `""` path keeps testable (Stage 4).
- **`uv-cancel!`'s else arm (`uv-check` on a third rc) — UNREACHABLE BY
  CONSTRUCTION, kept honest.** The domain check excludes every kind for
  which `uv_cancel` answers `UV_EINVAL`, and a live registered DNS
  pointer names a genuine threadpool request, for which the vendor
  answers only 0 or `UV_EBUSY` (threadpool.c:399-441). Routed through
  `uv-check` so a hypothetical third answer raises by name instead of
  becoming a silent `#f`.
- **M2's ASan blindness** (see the table): the copy-before-free decision
  is suite-caught on the plain build and valgrind-caught on Linux; the
  macOS ASan arm structurally cannot see it. Recorded so nobody later
  "confirms" the mutation is covered by the sanitizer leg. The Linux
  observation (below) added a third posture to the record: under
  Memcheck the SUITE is also blind — the reverse rows PASSED on the
  mutated run because Memcheck's freelist deliberately delays reuse of
  a freed block (the same `--freelist-vol` property Makefile:418-424
  documents for the dirty-memory seed), so the stale contents were
  still intact at delivery time and only the `Invalid read` records
  fired. Three legs, three different catchers: plain build → by-name
  rows, Linux valgrind → addressability errors, macOS ASan → nothing.
- **M12** was gate-deferred to Linux valgrind (with M2's valgrind
  observation and Stage 4 M3's, all pending the next CI run — Stage 6's
  CI-green exit criterion is where they were to land). **All three were
  observed on 2026-08-21** in the dedicated observation run — see
  "Linux valgrind observation" below and the stage-4 log's twin section.
- **The `uv-loop-close!` EBUSY row is vendor-guarded, not mutated**: the
  check IS `uv_loop_close`'s own `uv__loop_alive` refusal
  (`vendor/libuv/src/uv-common.c:885`); there is no binding-side decision
  to mutate (ADR-0011 explicitly declined a Scheme-side twin check). The
  row exists to pin the surfacing contract (symbol `'EBUSY`, loop
  untouched, usable, then closes cleanly after the drain).
- **The double-cancel row's second-`#t`** pins vendor re-queue behavior
  (threadpool.c:399-441, verified-facts row, spec §7); a mutation would
  have to edit vendored libuv, which this project never does. The
  binding-side decisions on that path (domain check, zeroed-ptr guard,
  rc policy) are M4/M6's coverage.

## Linux valgrind observation (2026-08-21, CI run 32509190939)

Harvested from the dedicated workflow "DNS Mutation Observation (spike)"
(branch `spike/dns-mutation-obs`, run 32509190939, conclusion success):
Ubuntu 24.04.4, Valgrind-3.22.0, the pkg-config build path (distro
`libuv.so.1.0.0`), Chez 10.4.1, against the v0.2-final tree. Sequence:
pristine control (green), stage-4 M3 (that log's twin section), then
this log's M2 and M12 — each applied by patch, run with
`make test-memory MEMORY_TESTS=tests/test-dns.sps`, reverted — then a
final control (green). Both controls, verbatim: `definitely lost: 0
bytes in 0 blocks`, `ERROR SUMMARY: 0 errors from 0 contexts
(suppressed: 0 from 0)`; `CONTROL GREEN: harness proven before any
mutation.` / `FINAL CONTROL GREEN: clean revert proven; three mutations
observed and reverted without leaving state behind.`

**Exit-code note, applying to both records below (and stage-4's M3):**
the "exit 9" this log predicted is valgrind's `--error-exitcode=9`
(Makefile:429); the recipe converts any valgrind failure via `|| exit 1`
(Makefile:433), make surfaces `Error 1` and itself exits 2, and 2 is
what the workflow steps observed. The marker lines, not the numeric
code, are what prove the gate fired on the predicted evidence.

### M2 (copy-after-free): the Invalid read records

The patch (`spike/dns/mutations/m2-copy-after-free.patch`, `1 file
changed, 8 insertions(+), 3 deletions(-)`) applied; verbatim from the
mutated run's output (elisions marked):

```
==6490== Invalid read of size 1
==6490==    at 0x7078B8A: ???
==6490==    by 0x819C168: ???
==6490==    by 0x1223C9: S_call_help (in /home/runner/work/chez-libuv/chez-libuv/.chez-install/lib/csv10.4.1/ta6le/scheme)
==6490==    by 0x6E5EFD1: ???
==6490==  Address 0x4b9a7fd is 1,277 bytes inside a block of size 1,456 free'd
==6490==    at 0x484988F: free (in /usr/libexec/valgrind/vgpreload_memcheck-amd64-linux.so)
[...]
==6490==  Block was alloc'd at
==6490==    at 0x4846828: malloc (in /usr/libexec/valgrind/vgpreload_memcheck-amd64-linux.so)
==6490==    by 0x1B97FC: s_malloc (in /home/runner/work/chez-libuv/chez-libuv/.chez-install/lib/csv10.4.1/ta6le/scheme)
[...]
# of expected passes      121
[...]
==6490== LEAK SUMMARY:
==6490==    definitely lost: 0 bytes in 0 blocks
[...]
==6490== ERROR SUMMARY: 100 errors from 1 contexts (suppressed: 0 from 0)
make: *** [Makefile:426: test-memory] Error 1
```

and the step's own verdict lines:

```
M2 run exit code: 2
M2 marker check: FOUND 'Invalid read'
M2 suite-failure check: NOT FOUND
M2 CONFIRMED: exit 2, Invalid-read marker present -- matches the stage-5 log's valgrind prediction.
```

The read is 1,277 bytes inside the freed 1,456-byte co-allocated block —
the moved `c-string->string` copy walking a result string out of the
freed request block (which buffer, host or service, the offset alone
does not say), precisely the mutation's shape. **What the table's
posture line predicted and what was observed differ in one place,
recorded honestly:** this leg's prediction was "invalid read and/or
suite failure"; the Invalid read appeared, the suite failure did NOT
(`M2 suite-failure check: NOT FOUND` — the freed block's contents were
still intact under Memcheck's reuse-delaying freelist, so every reverse
row rendered correctly and passed). The plain build's by-name record
stands as the plain build's; it does not transfer to this leg.

### M12 (pre-registration guard's free! dropped): the definite leak

The patch (`spike/dns/mutations/m12-abandon-free-dropped.patch`,
`1 file changed, 1 insertion(+), 1 deletion(-)`) applied; verbatim from
the mutated run's output (elisions marked):

```
# of expected passes      121
[...]
==7370== 1,456 bytes in 1 blocks are definitely lost in loss record 6 of 7
==7370==    at 0x4846828: malloc (in /usr/libexec/valgrind/vgpreload_memcheck-amd64-linux.so)
==7370==    by 0x1B97FC: s_malloc (in /home/runner/work/chez-libuv/chez-libuv/.chez-install/lib/csv10.4.1/ta6le/scheme)
[...]
==7370== LEAK SUMMARY:
==7370==    definitely lost: 1,456 bytes in 1 blocks
==7370==    indirectly lost: 0 bytes in 0 blocks
==7370==      possibly lost: 0 bytes in 0 blocks
==7370==    still reachable: 3,423 bytes in 10 blocks
==7370==         suppressed: 0 bytes in 0 blocks
[...]
==7370== ERROR SUMMARY: 1 errors from 1 contexts (suppressed: 0 from 0)
make: *** [Makefile:426: test-memory] Error 1
```

and the step's own verdict lines:

```
M12 run exit code: 2
M12 marker check: FOUND 'definitely lost:' with nonzero bytes
M12 CONFIRMED: exit 2, definite-leak marker present -- matches the stage-5 log's prediction.
```

One block, 1,456 bytes, alloc'd through Chez's `s_malloc` — the
co-allocated `[uv_getnameinfo_t | pad16 | sockaddr_storage]` block the
garbage-address path allocated and, under the mutation, never freed:
suite-blind exactly as the table records (121 passes on the same run),
caught by the gate alone.

## Gate tails (macOS arm, Darwin/arm64, final verification run)

- `make build`: exit 0 (no shim changes; relink-guard quiet).
- `make test`: 11 suites, **ALL SUITES PASSED**, exit 0 — test-dns 121
  (77 at Stage 4 + 44 net new), every other suite at its baseline
  (addrinfo 41, conditions 94, echo 32, facade 41, lifecycle 64, loop
  119, native 220, shim-loading 24, tcp 168, timer 128).
- `make check-purity`: exit 0 — `purity holds: tests/test-conditions.sps`
  and `purity holds: tests/test-addrinfo.sps`, `CHEZ_LIBUV_SHIM`
  poisoned.
- `make test-memory` (macOS ASan arm): exit 0, all 11 suites under the
  preload (`detect_leaks=0`, `MallocNanoZone=0`); three consecutive green
  runs after the teardown-row rework (the pre-rework failure is quoted in
  full above). Leak claims remain Linux CI's (ADR-0003).
