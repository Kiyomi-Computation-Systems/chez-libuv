# Stage 6 Mutation Log

Task 10 closes this series. Stage 6 adds no new library code: what it adds is
the **capstone** (`tests/test-echo.sps`), the **release guard**
(`FLAVOR`/`relink-guard`/`check-prod` in the `Makefile`, plus
`tests/check-prod.sps`), and the unwind-safety fix to `run-until/ticking` in
`tests/uv-testing.sls` that Task 9's review required.

That changes what a mutation log is for at this stage. The capstone's "code
under test" is partly the **echo program written inside the suite** — the
whole point of the suite is that such a program can be written from
`(import (libuv))` and that it works — so mutations here fall into two
groups, and both are recorded:

- mutations of the **echo program** (does the suite notice a server that
  frames its echo wrongly, a payload set that is not distinct, a teardown
  that never happens?), and
- mutations of the **libraries the capstone exercises end to end** (does an
  end-to-end suite still catch a read path that delivers a short span, a
  write that ignores its span start, an alloc dispatcher that answers a
  sub-range, a read buffer that is never freed?).

The second group matters most: a green capstone that survives real breakage
in `src/` would be a 512 KiB smoke test wearing an integration test's name.

## Red before green

The capstone was written whole, with **one line missing**: the peer's
`uv-write!`. A server that reads and never echoes. That is the honest red
state for a suite whose implementation is the program inside it — the loop,
the connections, the clients and the teardown all exist, and every assertion
that depends on bytes coming back fails on its own terms rather than on an
unbound identifier.

`…/scratchpad/stage6-red-run.txt`:

```
%%%% Starting test echo
FAIL the designated client stopped its own read from inside a delivery
FAIL the server echoed all seven writing clients' payloads back
FAIL a stopped reader receives nothing, however much the server echoes
FAIL the restart ran from inside another client's delivery, with the stopped client's count unmoved
FAIL every client received a full 32 KiB back
FAIL client 0 received back exactly the bytes it sent
FAIL client 1 received back exactly the bytes it sent
FAIL client 2 received back exactly the bytes it sent
FAIL client 3 received back exactly the bytes it sent
FAIL client 4 received back exactly the bytes it sent
FAIL client 5 received back exactly the bytes it sent
FAIL client 6 received back exactly the bytes it sent
FAIL client 7 received back exactly the bytes it sent
FAIL all seventeen handles closed cleanly
FAIL every peer saw exactly one EOF, and none of them read an error
FAIL the loop has nothing left to run
FAIL the facade's live-handle snapshot is empty before teardown
  [informational] on-data deliveries: clients=0 peers=9 bytes echoed=0
# of expected passes      13
# of unexpected failures  17
```

Thirteen rows pass in that state and they are the right thirteen: the seeds,
the connection phase, the seventeen-handle peak and the sixteen read buffers
— everything that is true of a server that accepts and reads but does not
answer. `peers=9` in the informational line is the server's deliveries: it
received all the traffic and echoed none of it.

Adding the `uv-write!` turns it green at 30 assertions.

## Method

Identical to `.plans/stage-{1,2,3,4,5}-mutation-log.md`:

1. The files under test were copied, once, to a scratch tree *outside* this
   repository —
   `…/scratchpad/stage6/mutation-scratch/{src/libuv/tcp.sls,src/libuv/private/{handles,native}.sls,tests/{uv-testing.sls,test-echo.sps,check-prod.sps}}`
   — each with a `.pristine` sibling. The repo's own files were never edited
   during mutation testing.
2. Each mutation edits *only* the scratch copy, from the pristine text, so
   mutations cannot stack. The driver refuses an anchor that is not unique in
   the file, so no edit can land somewhere other than where it was aimed.
3. The suites run from the repo, unmutated, against the mutated tree:
   `CHEZSCHEMELIBDIRS=<scratch>/src:<scratch>/tests:src:tests:build/scheme-libs`,
   which shadows exactly the libraries that were copied and resolves
   everything else (`config.sls`, conditions, constants, loop, timer, handle)
   from the repository.
4. The two `Makefile` mutations are run with `make -f <mutated copy>` from
   the repo, since a Makefile cannot be shadowed by a search path.

## Summary

Fifteen mutations. Fourteen caught by name; one recorded as equivalent, with
the reasoning below rather than a silence.

| # | File | Mutation | Caught by |
|---|---|---|---|
| 1 | `tests/test-echo.sps` | the peer echoes `bv start (- end 1)` — a wrongly framed span | all eight `client N received back exactly the bytes it sent`, plus `every client received a full 32 KiB back` and four teardown rows (13 rows) |
| 2 | `tests/test-echo.sps` | client 3's payload seeded 2 instead of 3 — two clients share a payload | `seed: the eight client payloads are pairwise distinct`, **and nothing else** |
| 3a | `tests/test-echo.sps` | `uv-loop-teardown!` skipped, the following `uv-loop-close!` left | *not caught — argued equivalent, see below* |
| 3b | `tests/test-echo.sps` | teardown **and** close skipped | `the loop is closed afterwards`; `a full collection after teardown leaves every counter at zero` |
| 4 | `handles.sls` | `read-dispatch` delivers `(bv 0 (- nread 1))` — one byte short per delivery | all eight equality rows, `the server echoed all seven writing clients' payloads back`, and five more (14 rows) |
| 5 | `tcp.sls` | `uv-write!` copies from offset 0 instead of the caller's `start` | the eight equality rows, **and nothing else** — the byte counts stay right, only the content is wrong |
| 6 | `handles.sls` | `free-read-buffer!` never frees | `a full collection after teardown leaves every counter at zero` |
| 7 | `handles.sls` | `alloc-dispatch` answers a **sub-range** (`base+1`, `len-1`) | the eight equality rows |
| 8 | `tcp.sls` | `uv-read-stop!` stops nothing (rc faked to 0, `uv_read_stop` never called) | `the restart ran from inside another client's delivery…` (3 runs of 3); `a stopped reader receives nothing…` (2 runs of 3) |
| 9 | `tests/test-echo.sps` | the restart is never issued from inside the delivery | `every client received a full 32 KiB back`, `client 0 received back exactly the bytes it sent`, and four teardown rows |
| 10 | `tests/test-echo.sps` | the restart is **hoisted out** of the delivery to the suite's top level | `a stopped reader receives nothing…`; `the restart ran from inside another client's delivery…` |
| 11 | `tests/uv-testing.sls` | `run-until/ticking` reverted to its pre-Task-10 form (no cleanup on the unwind path) | `tests/test-lifecycle.sps`: `the ticking fixture disarmed its own timer on the unwind path` (2 instead of 1) |
| 12 | `tests/check-prod.sps` | the verdict inverted — moving counters would PASS | the probe FAILs against the prod shim it should pass |
| 13 | `tests/check-prod.sps` | the live-scope witnesses removed: the probe observes the counters without allocating anything | `check-prod: FAIL: the probe never had a live scope -- no ephemeral port was bound: unset` |
| 14 | `Makefile` | `$(FLAVOR_STAMP)` dropped from `$(SHIM)`'s prerequisites | `make build FLAVOR=prod && make test` → 45 counter rows fail across five suites |
| 15 | `Makefile` | the flavor stamp kept but `relink-guard` removed | `make prod && make test` **in the same second** → the same 45 rows. **This was the real defect, found by running the guard rather than by reading it** — see below |

### Mutation 15 is not hypothetical; it shipped for an hour

The stamp mechanism this task set out to add — `build/.flavor-<name>`, a
prerequisite of `$(SHIM)`, so a flavor flip forces a relink — **does not
work on make 3.81**, which is the make macOS ships and therefore the one that
runs `make prod && make test` on this machine. 3.81 compares mtimes at
one-second granularity and treats *equal* as up to date. A flip recreates the
stamp in the same second as the previous link whenever the two commands run
back to back, and the shim is then not relinked at all.

It was caught by running the sequence, not by reading the rule: `make prod`
followed immediately by `make test` produced

```
### make test after prod
rm -f build/.flavor-*
touch build/.flavor-dev
…
FAIL seventeen tcp handles are live at the peak of the exchange
FAIL sixteen read buffers are live at the peak -- one per reading handle
…
SUITE FAILED
```

— the stamp rule ran, no `cc` line followed it, and 45 counter rows across
`echo`, `lifecycle`, `loop`, `native`, `tcp` and `timer` failed against the
`-O2` artifact. Ninety seconds earlier the same two commands, run with a
pause between them, had passed: the stamp landed in a *later* second and the
relink happened. A guard whose correctness depends on how fast you type is
not a guard.

`relink-guard` is the fix, and it does not compare timestamps at all: it
deletes a shim whose recorded provenance no longer matches what was asked
for, and a missing shim is rebuilt whatever the clock said. It covers the
acquisition stamp too, which has exactly the same defect for exactly the same
reason (`make build && make HAVE_PKG=no build` in one second) — with one
accidental mitigation: under `HAVE_PKG=no` the shim also depends on the phony
`vendor` target, so that direction always relinked. The pkg-config direction
did not.

Verified in both directions, in the same second, with the guard in place:

```
--- make prod ---
cc … -O2 … -o build/lib/libchezlibuv.dylib
check-prod: PASS: every counter read 0 while a bound tcp handle (port 54115) was live on the loop; the shim is a prod (counters-free) build
--- make test (SAME SECOND as prod's link) ---
relink-guard: shim provenance changed (flavor=dev, acquisition=pkgconfig); relinking
cc … -g -O0 -DCHEZ_LIBUV_DEBUG_COUNTERS …
ALL SUITES PASSED
--- make check-prod (must FAIL: the artifact is dev again) ---
The shim was linked with dev flags (-DCHEZ_LIBUV_DEBUG_COUNTERS).
make: *** [check-prod] Error 1
--- make build again (no flip: must NOT relink) ---
(no output: nothing was rebuilt)
```

## Uncovered, and why

**Mutation 3a (`uv-loop-teardown!` skipped) is equivalent, not undetected.**
The capstone is a well-behaved program: it closes all seventeen handles
explicitly and drains them before it tears down, so by the time
`uv-loop-teardown!` runs there is nothing left for its sweep to close and it
does exactly what the `uv-loop-close!` on the next line does. Removing one of
two calls that do the same thing changes no observable. Removing **both**
(3b) is the mutation that has meaning, and it fails two rows by name. The
alternative — leaving the listener unclosed so that teardown's sweep has a
job — was rejected: a listening handle keeps the loop alive, so it would cost
the `the loop has nothing left to run` row, which is a stronger assertion
than the one it would buy.

**"From inside a delivery" is structural, and only half of it is directly
observable.** The row `the restart ran from inside another client's delivery,
with the stopped client's count unmoved` asserts two things. The second half
— that the stopped client's byte count had not moved — is what mutations 8
and 10 break, by name. The first half is a property of *where the call
appears in the file*, and mutation 9 (deleting the restart) is caught by six
downstream rows rather than by this one, because the sentinel is recorded
beside the call. It is recorded after `uv-read-start!` returns, so a restart
that *raised* leaves the sentinel in place; a restart that was never written
at all is caught by client 0 never completing. That is the honest boundary,
and the six-row detection is not weaker for being indirect.

**Fragmentation is not asserted anywhere and must not be.** How libuv splits
512 KiB of loopback traffic into `on-data` deliveries is kernel policy: on
this machine the runs alternate between 9 and 10 client deliveries with no
change to the code. The counts are printed as an informational line. A suite
that asserted them would fail on a different kernel while nothing was wrong.

**The capstone's `(libuv)`-only import claim has no mutation, because it is
enforced by the expander rather than by an assertion.** A name the facade
stops exporting is an unbound identifier at expand time — the suite does not
run at all. That is the strongest available check for a re-export list and it
is the same mechanism `tests/test-facade.sps` documents.

## Notes on individual mutations

**Mutation 2 is the one that justifies the other eight.** With clients 2 and
3 sharing a payload, all eight `received back exactly the bytes it sent` rows
stay green — a server that crossed those two streams would hand each client
32 KiB that still compares equal to what it sent. Exactly one row moves, and
it is the seed. This is AGENTS.md's "a test that passes whether the code is
right or wrong" caught in the act: without the distinctness seed, two of the
eight equality rows would be empty assertions.

**Mutation 5 is the cleanest signal in the table.** `copy-in!` from offset 0
instead of `start` corrupts chunks 2 and 3 of every payload and nothing else:
the byte counts are right, every handle closes, every counter balances, and
precisely the eight rows that compare content fail. An end-to-end suite that
only counted bytes would be green.

**Mutation 8's detection is split across two rows, and the split is real.**
`a stopped reader receives nothing…` is evaluated at the moment the server's
echo writes have all completed, and whether the un-stopped client's *delivery*
has already been dispatched by then is a loop-interleaving question — it had
in two runs of three. `the restart ran from inside another client's
delivery…` failed in all three, because by then the client has finished and
closed itself and the hook records `stopper-already-finished`, a sentinel no
correct run can produce. Before that sentinel existed the same mutation
killed the suite with `&uv-handle-closed` escaping a callback — a real
detection, but a crash rather than a named row, which is why the hook now
checks `uv-handle-open?` first.

**Mutation 11 is the Task 9 review item, and it is what the capstone leans
on.** The pre-fix `run-until/ticking` disarmed its 1 ms ticker only on the
path where the wait *returned*; a wait ended by a raise left it armed, and
every later assertion measured a loop the fixture was still holding open. The
guarding row reads the live timer count from inside the raising callback (2 —
the raising timer and the ticker) and asserts 1 afterwards.

## Verification runs behind this log

All on macOS 25.5.0 / arm64, Chez 10.4.1, libuv 1.52.1, GNU make 3.81, dev
shim (`CFLAGS_DEV`, `-DCHEZ_LIBUV_DEBUG_COUNTERS`) except where stated:

| Run | Result |
|---|---|
| `make test` (pkg-config leg) ×2 | ALL SUITES PASSED, exit 0 both times — 812 assertions |
| `make HAVE_PKG=no test` (vendored leg) ×2 | ALL SUITES PASSED, exit 0 both times — same 812 |
| `make check-pins`, `make check-purity`, `make check-help` | green on both legs |
| `make check-prod` against a **dev** shim | FAILS, exit 1, naming the counters that moved (recorded verbatim in the Task 10 report) |
| `make prod` (both legs) | clean → `-O2` link → `check-prod: PASS` |
| `make test` immediately after `make prod` (both legs) | `relink-guard` fires, the shim relinks dev, ALL SUITES PASSED |
| `make test-memory` (macOS ASan preload) | exit 0, every suite passed, **no sanitizer diagnostic**. Not a leak claim: LeakSanitizer is unsupported on arm64 and ADR-0003 makes Linux Valgrind the sole memory gate. What it does show is that this stage's workload — seventeen TCP handles, 512 KiB through sixteen reused 64 KiB buffers, and a read stopped and restarted from inside callbacks — produces no use-after-free or double-free that ASan can see. |
| `tests/test-echo.sps` alone, five consecutive runs | 30 assertions, identical every time; 0.4 s wall each (the design spec's budget was 30 s) |

Per-suite assertion counts, identical across every `make test` run:
`conditions` 89, `echo` 30, `facade` 40, `lifecycle` 64, `loop` 106,
`native` 170, `shim-loading` 19, `tcp` 166, `timer` 128.
