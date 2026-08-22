# Process Stage 3 Mutation Log

Task 5: `src/libuv/private/handles.sls`'s `uv-stream-record` hierarchy
(`uv-tcp-record` and `uv-pipe-record` children, `uv-process-record` as a
direct `uv-handle-record` child), the `stream-*` accessor renames (six pairs,
`tcp-on-connection` excepted), `handle-kinds` widened to
`'(timer tcp pipe process)`, `count-handle-free!`'s pipe/process arms, and
the walk QUERY machinery (`walk-query-cell`, `walk-dispatch`,
`handle-in-loop-queue?`) exported but NOT installed (ADR-0015; the install is
Task 8's, from `(libuv process)`'s library body). Behavior-preserving for
every reachable path: the new pipe/process records have no public
constructor yet (Tasks 6 and 8), so nothing in the existing suite can
construct one. Also touches `src/libuv/tcp.sls` (accessor renames only) and
`tests/test-tcp.sps` (accessor renames only — `rg` found no hits in
`tests/test-lifecycle.sps` or `tests/test-echo.sps`).

## Method

Per AGENTS.md ("a test is not finished when it passes; it is finished when
you have watched it fail") applied to a refactor rather than new behavior:
Step 1 recorded the pre-edit baseline, the restructuring landed, Step 5
reconfirmed the SAME totals (nothing this task changes is exercised by a new
assertion — Tasks 6/8 add that coverage), and three probes were then run
against the committed tree and reverted: two are the brief's named
forward-obligation probes (both expected GREEN today, discharged later),
and the third is the live probe this task's own coverage can catch.

## Baseline (Step 1, before the first edit)

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        240
=== tests/test-shim-loading.sps ===   24
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===         128
ALL SUITES PASSED
```
1099 passes, 0 failures, 11 suites.

## After the restructure (Step 5)

Identical run, same eleven suites, same per-suite counts, `ALL SUITES
PASSED`:

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        240
=== tests/test-shim-loading.sps ===   24
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===         128
ALL SUITES PASSED
```
1099 passes, 0 failures, 11 suites — no change from baseline, confirming the
restructure is behavior-preserving for every path the existing suite
reaches.

## Forward-obligation probes (Step 6, items 1 and 2 — both expected GREEN today)

### Probe 1: revert `free-read-buffer!`'s predicate to `uv-tcp-record?`

**Mutation:** in `free-read-buffer!`, `(when (uv-stream-record? handle) ...)`
reverted to `(when (uv-tcp-record? handle) ...)`, leaving the body's
`stream-read-buf`/`stream-read-buf-len` accessors untouched.

**`make test` output:** unchanged from the post-restructure run above —
`ALL SUITES PASSED`, all eleven suites at their Step-5 counts, no failures.

**Result:** GREEN (no observable difference), exactly as the brief predicts:
no `uv-pipe-record` exists in this suite (no public constructor is wired
until Task 9), so `uv-tcp-record?` and `uv-stream-record?` are
indistinguishable to every test that runs today. **Forward obligation:**
discharged by Task 9's echo test for the pipe path (pipe read buffer freed
on close, counters balanced) — under this mutation a pipe's read buffer
would never be freed at close time, and that test's counter-balance
assertion would catch it. Reverted; confirmed green again before the next
probe.

### Probe 2: drop `'pipe` from `handle-kinds`

**Mutation:** `(define handle-kinds '(timer tcp pipe process))` reverted to
`(define handle-kinds '(timer tcp process))`.

**`make test` output:** unchanged from the post-restructure run above —
`ALL SUITES PASSED`, all eleven suites at their Step-5 counts, no failures.

**Result:** GREEN (no observable difference). `handle-kinds` gates
`registry-snapshot-for-loop`, which is what `uv-loop-teardown!` sweeps to
close — with no pipe ever registered against any loop in this suite (same
reason as Probe 1: no public pipe constructor exists yet), a pipe entry
missing from the sweep filter is unreachable. **Forward obligation:**
discharged by Task 6's teardown-sweep row — once pipes are constructible, a
teardown test that opens a pipe and never explicitly closes it would find
the handle still registered (and the loop's registry non-empty) instead of
swept, under this mutation. Reverted; confirmed green again before the next
probe.

## Live probe (Step 8's third item): swap `stream-read-buf`/`stream-read-buf-len` in `alloc-dispatch`

The brief's other two suggested live probes are not applicable as written:
kind-threading (constructing a tcp handle with `kind 'pipe`) needs no new
public surface to observe from *outside* handles.sls, since
`%make-uv-tcp-record` is `%`-prefixed and private-by-convention — there is
no way to drive it with a wrong kind through any public API, so that probe
is skipped per the brief's own "skip live probes that need new public
surface" clause. In its place, the brief names the alloc-dispatch
argument-order swap as the substitute live probe.

**Mutation:** in `alloc-dispatch`, the two arguments to `uv-buf-set!` were
swapped —

```scheme
(uv-buf-set! buf-ptr (stream-read-buf-len handle) (stream-read-buf handle))
```

instead of

```scheme
(uv-buf-set! buf-ptr (stream-read-buf handle) (stream-read-buf-len handle))
```

— so libuv's `alloc_cb` is handed the buffer's *length* as the base pointer
and the *pointer* as the length, on every read.

**`make test` output, verbatim (only the failing suites shown; every other
suite's count is identical to the post-restructure run above and is
omitted here for length — the full run is captured for the record):**

```
=== tests/test-echo.sps ===
FAIL the designated client stopped its own read from inside a delivery
Exception in uv-write!: broken pipe
=== tests/test-facade.sps ===
FAIL uv-read-start! is re-exported and delivered the payload to the peer
FAIL reading through the facade fired no error callback
# of expected passes      47
# of unexpected failures  2
=== tests/test-tcp.sps ===
  [informational] write after shutdown: sync=EPIPE async=not-attempted
  [informational] write racing close completed as: no-error
FAIL the peer's on-data callback delivered the client's write
FAIL on-data is handed the span (0 . nread) over a bytevector of exactly nread bytes
FAIL the bytes the peer read are the bytes the client wrote
FAIL delivering data fires neither on-eof nor on-error
Exception in uv-read-start!: socket is not connected
SUITE FAILED
make: *** [test] Error 1
```

**Result:** GREEN (failure detected, and more broadly than the brief's
phrasing anticipated). The brief asks "which existing tcp read test fails" —
the answer is four named `test-tcp.sps` assertions plus an uncaught
exception (`uv-read-start!: socket is not connected`) that aborted that
suite's run outright, which is itself informative: a garbage base pointer
handed to a real read makes libuv's own connection bookkeeping fail before
Scheme-level assertions even get to run. The blast radius is wider than
`test-tcp.sps` alone — `test-echo.sps` (one assertion plus an uncaught
`uv-write!: broken pipe` exception, itself a downstream symptom of the
corrupted read side wedging the connection) and `test-facade.sps` (two
assertions, `uv-read-start!` re-exported through the facade exercises the
identical alloc/read path) also fail, because every one of these suites
drives a real TCP read through `alloc-dispatch`. Reverted immediately after
capturing this output; `make test` reconfirmed `ALL SUITES PASSED` at the
Step-5 totals (1099 passes, 0 failures, 11 suites) before commit.

## Gate tail (post-revert, pre-commit)

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        240
=== tests/test-shim-loading.sps ===   24
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===         128
ALL SUITES PASSED
```
1099 passes, 0 failures, 11 suites — identical to the baseline and to the
post-restructure run; no probe mutation was left in the tree.

## Coverage notes

- The new `uv-pipe-record`/`uv-process-record` types, `pipe-connected?`,
  `process-on-exit`/`process-exited?`, and the walk query machinery
  (`walk-query-cell`, `walk-dispatch`, `handle-in-loop-queue?`) are
  UNCOVERED BY DESIGN this task, per AGENTS.md: nothing in the existing
  suite can reach them, because no public constructor for either record
  exists until Task 6 (`%make-uv-pipe-record` behind `uv-pipe-open!`) and
  Task 8 (`%make-uv-process-record` behind `uv-spawn!`, and the
  `install-dispatch-procedure! 'walk walk-dispatch` install itself). This
  mirrors the DNS Stage 2 log's and this branch's own Stage 2 log's
  equivalent notes for callback bodies with no caller yet.
- `handle-in-loop-queue?`'s only consumer as of this task is nothing at
  all — it is exported and otherwise inert until `(libuv process)` calls it
  from the ADR-0015 spawn-failure discriminator (Task 8). It was checked by
  inspection against `spike/process/07-spawn-failure.ss`'s `walk-handles`
  helper (reset the accumulator, `uv_walk`, membership test) rather than by
  a test, since no loop/handle pair exists in this suite that would let a
  test drive `uv_walk` meaningfully without a process handle to ask about.
