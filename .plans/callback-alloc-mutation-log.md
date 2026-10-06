# Callback allocation (#45): mutation log

Evidence for `fix/callback-alloc`. #45, filed from chez-http-server's
whole-server allocation profile, asked chez-libuv to allocate less around
each callback, keeping how a raise is recorded. Four changes, all in Scheme;
the shim is unchanged:

1. **One containment per callback.** The seam's `guard` was the outer of
   two: most dispatchers wrapped the user's procedure in `dispatch-guarded`,
   a second `guard`. The seam now looks the pointer up once, before it calls
   the dispatcher, hands the dispatcher the registered object, and is the
   only containment; dispatchers call user code directly, and last.
2. **Fixed-arity seams.** A `case-lambda` per seam, not a rest-argument
   lambda and `apply`.
3. **`uv-run` without `dynamic-wind`.** The running mark is set before the
   call and cleared when `uv_run` returns. `call-with-uv-loop`'s exit clears
   a mark its own thread left before tearing its loop down.
4. **Status checks in `uv-write!`, `uv-write*!`, `uv-shutdown!`**, in place
   of a `guard` around each native start.

The issue's fifth item, answering libuv's alloc callback in the shim, is a
follow-up: it adds a sixth kind of shim export and needs ADR-0002 and
ADR-0008 amended and a shim rebuild.

Every probe and mutation ran on a scratch copy outside the repo. Platforms:
macOS arm64 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config, the dev
build); Linux aarch64 in the `chez-libuv-valgrind:10.4.1` image (Debian
bookworm, vendored libuv 1.52.1, `HAVE_PKG=no`); Linux x86_64 in the same
Dockerfile built with `--platform linux/amd64` and run under emulation, built
from a `--no-hardlinks` clone.

---

## The issue's design, probed

The issue argued that `uv-run` no longer needs its `dynamic-wind` because
"the seams already contain every raise, so nothing escapes through the C
frame". The premise is false: a raise is not the only way out of a callback.
An engine that runs out of fuel in a callback suspends it, and a continuation
can escape it. CSUG §4.4 makes both legal: Chez does not reset the C stack on
a non-local exit, and a foreign frame stays valid until something returns
beneath it. The conclusion held up anyway, and for a better reason. Probes
on v0.7.3 (`v0`) and on v0.7.3 with only the `dynamic-wind` removed (`nodw`):

| probe | v0 | nodw |
|---|---|---|
| E1: a continuation escapes a timer callback, never resumed | mark cleared; `uv-run` and teardown work | mark kept; `uv-run` and teardown refuse `'loop-running` |
| E2: `uv-run` inside an engine, fuel out inside a callback | mark **cleared** during all 120 suspensions | mark kept during all 120; both runs complete |
| E2b: E2, then `uv-loop-teardown!` while suspended, then resume | teardown **accepted**, resume dies: `invalid memory reference` | teardown refused; resume runs |
| E3: escape out of one close callback while a second handle closes | the second close never runs: handle stuck `'closing`, re-run does nothing, teardown raises `EBUSY` | refused |

E2b is a use-after-free on v0.7.3: the `dynamic-wind` cleared the mark
whenever control left `uv-run`, including when an engine suspended it with
libuv mid-iteration. E3 shows that re-running a loop after an abandoned
escape was never sound. libuv runs its closes from a list it has already
detached, so an escape strands the rest of the batch.

What an abandoned escape costs, measured on a loop that owned a listener, a
connected pair (both reading), a timer, a SIGINT watcher and a child. The
right column is the option the user weighed and rejected for
`call-with-uv-loop` ("skip teardown if running"):

| | torn down (v0.7.3, and this branch's `call-with-uv-loop`) | left marked running |
|---|---|---|
| native objects | none | the loop, 3 TCP handles, timer, signal, process, 2 read buffers: ~130 KiB |
| a 1 MiB bytevector a callback captured | collected | survives a full collection (the registry keeps it) |
| descriptors | 0 | 8, 3 of them sockets |
| the listening port | free | `EADDRINUSE` |
| a new client | — | connects, then hears nothing |
| SIGINT | kills the process (exit 130) | swallowed for good |

Under both, each abandoned escape strands 352 B of C stack: 1,000 escapes
moved it 352,000 B on v0.7.3 and on the branch. A child that exits after the
escape is a zombie under both.

`call-with-uv-loop` with an engine whose fuel runs out inside a callback:

| exit thunk | outcome |
|---|---|
| v0.7.3 | loop torn down; resume raises `&uv-handle-closed` |
| unchanged, after `nodw` | the teardown's `'loop-running` raise lands in the engine's expiry: `no engine active` |
| skip teardown if running (rejected) | completes after 121 suspensions |
| clear this thread's mark, then tear down (chosen) | loop torn down; resume raises `&uv-handle-closed`, as v0.7.3 |

The chosen exit keeps v0.7.3's behaviour exactly. The owner check keeps it
from tearing down a loop another thread is running: that loop's teardown
refuses it, as on v0.7.3.

## The containment's shape

The first shape tried used a one-shot continuation, `call/1cc` with the
continuation itself as the exception handler. Measured with empty callbacks
only, it looked like the cheapest. Measured with a callback that has a `guard`
of its own, as chez-http-server's do, it was a trap. Bytes per timer
callback, delivered by `uv-run 'once`, the run's 16 B included, least mean
over windows of 1,000:

| seam | empty | own `guard` (`#t`) | own `guard` (`else`) | own `call/cc` | own `call/1cc` |
|---|---|---|---|---|---|
| v0.7.3 (two guards) | 1125 | 1491 | 1475 | 1265 | 1347 |
| one `guard`, `#t` clause | 480 | 834 | 826 | 616 | 763 |
| **one `guard`, `else` clause** | **464** | **826** | **810** | **599** | **747** |
| `call/cc`, continuation as handler | 531 | 820 | 745 | 600 | 747 |
| `call/1cc`, continuation as handler | 336 | **4108** | **4102** | **3888** | 420 |

A full continuation captured inside the seam's extent makes Chez promote the
seam's one-shot continuation and copy the stack. The branch uses one `guard`
with an `else` clause, which takes Chez 10.4.1's other `$guard` path: 16 B
less than `#t` on every callback.

## The meter

`tests/test-callback-alloc.sps` reads `(+ (bytes-allocated)
(bytes-deallocated))`. That is the total ever allocated, so a collection
cannot run it backwards, and the read allocates nothing: a pair reads 16 B,
an empty call 0 B. The test holds the collector off and meters each call on
its own, with its set-up outside the meter.

The first version took a mean over windows of calls, as the issue's program
does, and it was noisy across runs. Over 20 runs, a close through libuv read
either ~402 B or ~600 B, and `uv-write!` either 240 B or 568 B. 568 B is
above v0.7.3's guarded write at 544 B, so that row could not tell the fix
from the regression it guards against.

Metering `uv-write!` call by call in isolation showed why. It allocated
exactly 240 B on 597–599 calls of 600, and 65,824 B on the other 1–3. That
is a fresh 64 KiB Scheme stack segment, needed after the `guard`s run
between calls had split the stack, and charged to whichever call overflowed.

So each row takes the FEWEST bytes over the calls that did the work. Every
decision the suite pins shows up as a cost on every call. Over 20 runs, each
row read one value.

One row takes a mean: a callback with a `guard` of its own. The cost it
guards against lands only on some calls. The `call/1cc` seam's cheapest such
call was 592 B, under the branch's 656 B, while its mean was 4,084 B.

## Measurements

`tests/test-callback-alloc.sps`, final. Every fewest row read the same value
on macOS arm64, Linux aarch64 and Linux x86_64 (3 runs each on Linux, 20 on
macOS). The guarded row reads 787 B on the arm64 platforms and 793 B on
x86_64. The bounds are relative ("Review fixes", below); on Chez 10.4.1 they
come to the branch's figure plus half a guard (128 B), plus half a
dynamic-wind (40 B) for an idle run, and plus two guards (512 B) for the
guarded mean:

| row | branch | v0.7.3 | bound |
|---|---|---|---|
| delivering 16 bytes read, with their copy | 368 | 736 | 496 |
| delivering an end of stream | 336 | 688 | 464 |
| delivering a read error, with its condition | 944 | 1312 | 1072 |
| delivering a connection | 336 | 688 | 464 |
| delivering a timer's firing | 320 | 672 | 448 |
| delivering a signal | 336 | 672 | 464 |
| delivering an async wake | 320 | 656 | 448 |
| delivering a process's exit | 336 | 688 | 464 |
| delivering a write's / shutdown's / connect's completion | 336 | 704 | 464 |
| delivering a getaddrinfo's completion | 656 | 1040 | 784 |
| delivering a getnameinfo's completion | 384 | 768 | 512 |
| a uv-run with nothing to do | 16 | 128 | 56 |
| a uv-run that delivers a timer's firing | 400 | 864 | 528 |
| ...a timer callback using a guard of its own, on the mean | 787 | 1446 | 1299 |
| a uv-run that delivers a handle's close | 400 | 848 | 528 |
| a uv-write! of 16 bytes, the call alone | 240 | 544 | 368 |
| a uv-write*! of one 16-byte segment, the call alone | 304 | 624 | 432 |
| a uv-shutdown!, the call alone | 128 | 432 | 256 |

The issue's own program on the branch (macOS arm64, three runs), against its
v0.7.3 figures at the same 1.5–1.6 `uv-run`s a round:

- an idle `uv-run 'nowait`: 16 B (128 B);
- a timer's start and the run that fires it: 532 B (1,050 B);
- a write round: 1,956 B (3,525–3,531 B).

## Red

On v0.7.3's `src/`, with this branch's tests:

- **`tests/test-loop.sps`, 9 rows fail by name.** Six are the behaviour:
  the four engine-suspension rows ("a loop whose run is suspended inside a
  callback is still marked running", and the `uv-run`, `uv-loop-close!` and
  `uv-loop-teardown!` refusals) and the two escape rows. The other three
  drive `complete-request!` directly, which now takes the request the seam
  found, so they call v0.7.3's with the wrong arguments.
  - Each refusal is tried only while the loop is marked running. On v0.7.3 it
    reads `not-marked-running` instead of running the loop under the
    suspended engine.
  - The `call-with-uv-loop` rows pass on v0.7.3. They pin behaviour the
    branch keeps.
- **`tests/test-callback-alloc.sps`, 21 rows fail by name**: the arity row
  (every slot's mask is -1) and every allocation row, the guarded mean
  included (1,446 B against 1,299 B).
- **`tests/test-stream.sps`'s three refusal rows pass on v0.7.3**, by
  design: they pin what the status checks must keep, and M21–M23 show they
  can fail.

## Mutations

Each mutation was applied to a fresh copy of `src/` by exact text
replacement. The harness aborts unless the target occurs once, re-checks the
edit, then runs the owning suites against the copy. A mutation counts as
caught only if every expected row fails by name. The final sweep, on the
tree after the review fixes, caught 39 of 42 by name; M14, M27 and M28 are
recorded as uncovered below. The harness exports `CHEZ_LIBUV_TEST_CHEZ`, as
`make test` does, so the rows that read tests/stranded-exit-child.sps run
instead of skipping.

| id | mutation | caught by |
|---|---|---|
| M01 | `timer-dispatch` wraps `on-timeout` in a second guard | delivering a timer's firing; a uv-run that delivers a timer's firing |
| M02 | the same in `connection-dispatch` | delivering a connection |
| M03 | the same in `complete-request!` (loop read before the deregister) | the write, shutdown, connect, getaddrinfo and getnameinfo completion rows |
| M04 | the same in `deliver-read-data!` | delivering 16 bytes read |
| M05 | the same in `deliver-read-eof!` | delivering an end of stream |
| M06 | the same in `deliver-read-error!` | delivering a read error |
| M07 | the same in `close-dispatch` | a uv-run that delivers a handle's close |
| M08 | the same in `signal-dispatch` | delivering a signal |
| M09 | the same in `async-dispatch` | delivering an async wake |
| M10 | the same in `exit-dispatch` | delivering a process's exit |
| M11 | the seam looks the pointer up after the raise, not before dispatch | test-timer: a raise from an on-close callback escapes `uv-loop-teardown!`; test-loop: the raise was recorded on the loop the registry entry named; test-dns: a raising on-complete re-raises from `uv-run` |
| M12 | the seam takes a rest list and `apply`s | every installed slot takes its trampoline's arguments with no rest list |
| M13 | the seam contains with `call/1cc`, the continuation as handler | ...a timer callback using a guard of its own, on the mean (4,084 B) |
| M15 | the seam contains nothing | test-timer: the re-raised condition satisfies `uv-callback-error?`; the callback-error's cause is the original condition object |
| M16 | `uv-run` sets and clears the mark in a `dynamic-wind` again | a uv-run with nothing to do; the six running-mark rows of test-loop |
| M17 | `uv-run` never clears the mark | uv-run leaves the running flag clear after it returns |
| M18 | `call-with-uv-loop` does not clear its own thread's mark | ...and call-with-uv-loop tore its loop down on the way out; an engine suspended in a callback does not keep call-with-uv-loop's loop |
| M19 | `call-with-uv-loop` clears any mark, whoever left it | call-with-uv-loop's exit refuses a loop another thread is running; ...and leaves that thread's mark in place |
| M20 | `call-with-uv-loop` skips the teardown of a loop marked running | ...tore its loop down on the way out; an engine suspended in a callback does not keep call-with-uv-loop's loop |
| M21a–e | `uv-write!` on a refusal: (a) leaves the request registered, (b) does not uncount it, (c) raises as another verb, (d) returns instead of raising; (e) guards its native start again | (a–d) a uv-write! libuv refuses raises its errno as uv-write! and leaves no request; (e) a uv-write! of 16 bytes, the call alone |
| M22a–e | the same for `uv-write*!` | the matching uv-write*! rows |
| M23a, c–e | the same for `uv-shutdown!`, which counts nothing | the matching uv-shutdown! rows |
| M24 | `close-dispatch` marks the handle closed after `on-close` | ...and marked it closed before its on-close raised |
| M25 | `complete-request!` zeroes the request after `on-complete` | ...and the request was deregistered and zeroed before on-complete raised |
| M26 | `exit-dispatch` marks the process exited after `on-exit` | the record was marked exited before on-exit raised |
| M29 | `call-with-uv-loop` raises a failed teardown in the middle of the exit | an escape out of a close callback, with another close pending, keeps its value; an engine suspended there expires instead of failing mid-suspension |
| M30 | `call-with-uv-loop` admits a return into the body while the loop is open | ...and refuses a return into the body; ...and its resume is refused like any other return into the body |
| M31 | `call-with-uv-loop` leaves a loop it could not tear down unmarked | ...leaves the loop marked running, since libuv cannot finish closing it; ...leaves its loop marked running |

Notes on individual mutations:

- **M24–M26** hold the rule that a dispatcher calls user code last. Before
  #45 that order did not matter, because `dispatch-guarded` let the steps
  after a raise run. Their rows pass on v0.7.3 too, and catch these
  mutations only now.
- **M06 and M08** first ran with an unbalanced parenthesis in the mutation
  text. Each crashed at library load ("missing definition…", "variable
  signal-dispatch is not bound"), and the harness reported them MISSED. They
  were fixed and re-run, and each is caught by its row.
- **M15** fails its two named rows and then kills the suite at the next
  uncontained raise, which is spike Q2's process death.
- **M18 and M20** each lost one expected row when the exit's fix landed.
  With the teardown contained, M18's escape still keeps its value. With the
  body running once, M20's resume is refused whether or not the teardown
  ran. Each is still caught by its other rows, and M30 now owns re-entry.
- After the review fixes changed the dispatchers' text, the targets became
  short substrings of the code (a call, not the call and its closing
  parentheses), so a mutation keeps its parentheses balanced by
  construction.

## Uncovered

- **M14: the seam's guard with a `#t` clause instead of `else`.** That
  costs 16 B a callback, inside every bound's 128 B margin. A bound tight
  enough to see it would hold only for one Chez version's code paths. Not
  pinned.
- **M27: a dispatcher looks its pointer up again** instead of taking the
  seam's object. The lookup allocates nothing and changes no outcome, only
  CPU time. Not pinned.
- **M28: a seam captures its name** instead of holding it as a literal.
  16 B a callback, inside the margin, as M14. Not pinned.
- **The stream pointer resolved before the request exists** (`stream.sls`).
  It moves `handle-pointer`, whose check can raise, ahead of the allocation.
  But an open stream's pointer is always valid, and nothing exported can
  forge an invalid one (`set-handle-ptr!` is private to `handles.sls`), so
  no test can produce the raise. Not pinned.

## Review fixes

PR #46's /code-review (high) reported eight findings. Six were fixed here.
The other two were left as they are:

- the write block that leaks when `copy-in!` refuses a span (a follow-up
  task);
- an abandoned escape leaving its loop marked running, which is the
  documented contract.

**An exit whose teardown libuv cannot finish.** The body leaves from inside
one close callback while a second close waits in libuv's batch. The exit's
teardown cannot close the loop, because libuv walks that batch from a list
it has already detached. Measured on the branch and on v0.7.3 alike:

- a continuation's escape was replaced by `EBUSY` from `uv-loop-close!`;
- an engine suspended there ended in "no engine active", and its
  continuation was lost;
- had the body been re-entered, the entry check would have admitted it,
  since the loop was still open, into a half-torn-down loop.

Now the exit contains the failure, leaves the loop marked running as any
abandoned run is, and runs the body once: a `left` flag refuses every
re-entry, whatever became of the loop. The stranded loop and handle stay
allocated, as before: libuv cannot finish that iteration.

The scenario leaks by nature, so tests/stranded-exit-child.sps runs it in a
child process, which the memory gate does not follow. Valgrind runs with
`--trace-children=no`, and on macOS the ASan preload never reaches a child
launched through `/bin/sh`, because SIP purges it. test-loop
checks the datum the child prints:

- red on the tree before the fix: six rows by name;
- green after it;
- each of M29 to M31 is caught by the rows named for it.

The child escapes again through its own continuation as soon as a return
gets in, so even a regressed build never hands control back to libuv's
abandoned frame.

**One registry lookup per callback.** The seam looked the pointer up
(`registry-loop-of`), and then each dispatcher looked it up again
(`registry-ref`). Now the seam looks it up once and passes the registered
object to the dispatcher, ahead of libuv's arguments. It contains a raise
with the loop of that same entry. `complete-request!` takes the request
too.
- Passing the object made the guard's body closure capture one more
  variable, 16 B on every callback: a timer's delivery went from 320 to
  336 B.
- Building each seam with its name as a literal (`seams` in `handles.sls`)
  takes the name out of both closures, and every row read its earlier
  figure again. `install-callback-dispatchers!` refuses a set that does not
  name every slot exactly once, so the list cannot drift from
  `dispatcher-names` unnoticed.

**Bounds that follow the Chez running them.** Absolute bounds would fail
row by row on a Chez whose `guard` costs more. Each path now declares its
bytes on 10.4.1 and how many guards it holds. The suite measures a guard
and a `dynamic-wind` of its own in the same run (256 B and 80 B on all
three platforms), and a bound is:

    bytes on 10.4.1 + guards x (a guard now - 256) + margin

- The margin is half a guard, or half a `dynamic-wind` for the idle run,
  or two guards for the guarded mean.
- A seed row requires both references to allocate, so a bound can never be
  built from a measurement that answered nothing.

**A measurement that raises cannot abort the suite.** `row` is now a macro
that evaluates its measurement inside a guard, so a raise becomes the row's
evidence. The exit row's fake process entry is therefore always
deregistered before teardown. Injected-failure probe, a raise in the exit
row's measurement:

- the suite as of 2e55a3c aborted (exit 255) before deregistering;
- this one fails that row by name and finishes (29 rows pass).

**test-loop's cleanups are rows.** `tear-down-row-loop` clears a stale
mark, takes the loop back for this thread, and tears it down inside a named
row. Injected-failure probe, the suspended engine never resumed:

- as of 2e55a3c the suite aborted at the unguarded teardown (exit 255);
- now it fails the two resume rows by name and finishes (171 rows pass).

**Shared evidence helpers.** `tests/uv-evidence.sls` exports `live-count`
and a total `describe`.
- Ten suites had the same `live-count`, and three had the same `describe`.
- `tests/test-echo.sps` keeps its `live-count`, over a counter query renamed
  at the facade's boundary.
- `tests/test-require-threaded.sps` keeps its `describe`, because it is a
  pure suite.
- The library reaches `(libuv private native)` and never `handles.sls`, so
  `tests/test-native.sps` can use it.

## Not changed

- The issue's fifth item: libuv's alloc callback still crosses into Scheme
  for every read, 352 B a read through its slot (400 B on v0.7.3). It is a
  follow-up PR.
- `getaddrinfo-dispatch` still guards its chain conversion, so that the
  chain is freed when the conversion raises. That is a second guard on a
  DNS completion, which is not a hot path.

## Gates

On the branch, macOS arm64:

- `make test`: 20 suites pass.
- `make test-threading`: 12 rows.
- `make test-memory` (ASan) passes all 20 suites, after `make
  check-memory-gate` showed the recipe still goes red on a planted libc
  overrun.
- `make check-purity` holds, and `make check-help` is silent.
- `make prod`: check-prod PASS.

`make test-memory-docker` (Linux aarch64, Valgrind, vendored libuv 1.52.1),
from a `--no-hardlinks` clone:

- `check-memory-gate` caught the store overrun, the libc overrun and the
  leak, stayed consistent on the possible leak, and printed MEMORY GATE CAN
  FAIL.
- Every suite's own Valgrind summary: 0 errors and 0 bytes definitely lost,
  at 778 to 5,311 allocations each (`test-callback-alloc.sps`: 5,311).
- The two forked children that `_exit` before exec report 117 B and 131 B
  definitely lost: the known fork artifacts, which never gate (ADR-0003).
