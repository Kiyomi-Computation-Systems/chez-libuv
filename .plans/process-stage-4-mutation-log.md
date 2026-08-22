# Process Stage 4 Mutation Log

Task 7: `src/libuv/stream.sls` extracted from `src/libuv/tcp.sls` (ADR-0014)
-- `uv-write!`, `uv-shutdown!`, `uv-read-start!`/`start-reading!`/
`default-read-buffer-size`/`ensure-read-buffer!`, `uv-read-stop!`, moved
verbatim except `require-open-tcp` -> `require-open-stream` (gate widened
from `uv-tcp-record?` to `uv-stream-record?`) and the `tcp` parameter name ->
`stream`. `src/libuv/tcp.sls` shrinks to `make-uv-tcp`, `uv-tcp-bind!`,
`uv-tcp-getsockname-port`, `uv-listen!`, `uv-accept!`, `uv-tcp-connect!`,
`uv-tcp-nodelay!`, re-exporting the four moved verbs from `(libuv stream)` so
every existing importer compiles unchanged; its private `require-callback`
copy and the `except (libuv private native) require-callback` workaround
(Task 4) are both gone now that the verbs that needed the copy have left.
`tests/test-stream.sps` is new (the gating matrix). `tests/test-tcp.sps`
needed three assertions' expected `reason` symbol updated from
`'not-a-uv-tcp` to `'not-a-uv-stream` (the kind-refusal rows for `uv-write!`,
`uv-read-start!`, `uv-read-stop!` against a timer) -- those three verbs'
kind check is no longer tcp-specific, so the reason they refuse a wrong-kind
handle with legitimately changed; `uv-tcp-bind!` and
`uv-tcp-getsockname-port` stay on `require-open-tcp` and keep
`'not-a-uv-tcp` unchanged.

## Method

Per AGENTS.md ("a test is not finished when it passes; it is finished when
you have watched it fail"): Step 1 wrote `tests/test-stream.sps` against the
not-yet-existing `(libuv stream)` and confirmed RED, the extraction and
shrink landed, Step 5 confirmed GREEN with the tcp regression suites at
their pre-extraction totals, and the two probes named in the brief were then
run against the committed tree and reverted.

## RED (Step 2, before `src/libuv/stream.sls` exists)

```
make test 2>&1 | grep -A3 "test-stream"
```

```
=== tests/test-stream.sps ===
Exception: library (libuv stream) not found
=== tests/test-tcp.sps ===
```

Expected failure, exactly as the brief predicts: the library does not exist
yet.

## Baseline tcp/echo totals (Step 1, before any edit, for the regression comparison)

```
=== tests/test-tcp.sps ===           168
=== tests/test-echo.sps ===            32
```

## GREEN (Step 5, after the extraction, shrink, and the three reason-symbol updates)

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        243
=== tests/test-pipe.sps ===           13
=== tests/test-shim-loading.sps ===   24
=== tests/test-stream.sps ===         10
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===          128
ALL SUITES PASSED
```

`test-tcp.sps` (168) and `test-echo.sps` (32) are IDENTICAL to the Step-1
baseline -- the real regression assertion of this task: every existing
importer of `uv-write!` / `uv-shutdown!` / `uv-read-start!` /
`uv-read-stop!` from `(libuv tcp)` compiles and behaves unchanged through
the re-export. `test-stream.sps`'s 10 passes include the informational row;
the observed unconnected-pipe errno on this platform (macOS/Darwin) is
**EBADF** (`uv_fileno`'s answer for a pipe with no fd yet -- uv_spawn is
what connects one, per THE SPEC §4.6 / vendor fact V3 -- the same EBADF
family test-tcp.sps's `uv-tcp-getsockname-port` row measures for an
un-connected tcp handle).

## Probe 1 (Step 6, item 1): narrow `require-open-stream`'s predicate back to `uv-tcp-record?`

**Mutation**, in `src/libuv/stream.sls`:

```scheme
  (define (require-open-stream stream who)
    (unless (uv-tcp-record? stream)          ; was uv-stream-record?
      (raise (make-uv-invalid-argument who 'not-a-uv-stream)))
    (require-open-handle stream who)
    stream)
```

**Command and output, verbatim** (`tests/test-stream.sps` alone):

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-stream.sps
%%%% Starting test stream
Exception occurred with condition components:
  0. &uv-invalid-argument
      who: uv-write!
      reason: not-a-uv-stream
```
(exit code 255; the process aborts here -- no `# of expected passes` line is
ever printed, because the exception escapes uncaught)

**Result:** FAILS, and more sharply than "the row fails" -- it takes the
whole suite down. The unconnected-pipe row's own guard is scoped to
`uv-errno-error?` only:

```scheme
(define unconnected-errno
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
    (uv-write! pipe (make-bytevector 1 7) nop)
    'no-error))
```

Under the real gate, `pipe` is a `uv-stream-record?` (a `uv-pipe-record`,
not a `uv-tcp-record`), so `require-open-stream` passes it through to
libuv and the guard's single clause exists to catch exactly the errno libuv
answers. Narrowed to `uv-tcp-record?`, `pipe` fails the kind check instead,
`uv-write!` raises `&uv-invalid-argument` with reason `'not-a-uv-stream` --
a condition the guard's clause does not match -- and R6RS `guard`
re-raises an unmatched condition rather than swallowing it, so the
exception propagates out of the whole `.sps` script. This is the sharpest
possible failure signature for the mutation the brief names: not a named
`test-assert` failure but an uncaught exception that aborts every
subsequent assertion in the suite (the closed-pipe row, the tcp regression
canary, and the teardown/counter rows never run at all). Reverted
immediately after capturing this; `tests/test-stream.sps` alone
reconfirmed 10 passes, no failures, before the next probe.

## Probe 2 (Step 6, item 2): swap the kind/state check order in `require-open-stream`

**Mutation**, in `src/libuv/stream.sls`:

```scheme
  (define (require-open-stream stream who)
    (require-open-handle stream who)           ; state check now FIRST
    (unless (uv-stream-record? stream)         ; kind check now SECOND
      (raise (make-uv-invalid-argument who 'not-a-uv-stream)))
    stream)
```

**Command and output, verbatim** (`tests/test-stream.sps`, then the
suites that also exercise a closed-stream refusal through the re-export):

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-stream.sps
%%%% Starting test stream
  [informational] unconnected pipe write: EBADF
# of expected passes      10

$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-tcp.sps
%%%% Starting test tcp
  [informational] write after shutdown: sync=EPIPE async=not-attempted
  [informational] write racing close completed as: no-error
  [informational] abrupt peer close delivered as: ECONNRESET (on-eof fires: 0)
# of expected passes      168

$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-echo.sps
%%%% Starting test echo
  [informational] on-data deliveries: clients=10 peers=9 bytes echoed=262144 client eofs=0 peer shutdowns=(no-shutdown-error no-shutdown-error no-shutdown-error no-shutdown-error no-shutdown-error no-shutdown-error no-shutdown-error no-shutdown-error)
# of expected passes      32

$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-facade.sps
%%%% Starting test facade
# of expected passes      49

$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-pipe.sps
%%%% Starting test pipe
# of expected passes      13
```

**Result:** GREEN -- no observable difference in any suite, contrary to
what the brief anticipated ("the closed-pipe row fails with the wrong
condition"). Traced rather than just re-asserted: `require-open-handle`
itself calls `require-handle` (an unconditional `uv-handle?` check) *before*
its own state check, so it already answers a DIFFERENT question from
`require-open-stream`'s kind gate -- "is this any kind of handle at all",
not "is this a stream". For every closed-stream row this suite (or
test-tcp.sps's, through the re-export) actually exercises, the handle under
test (`pipe`, `closed-tcp`) IS a real stream record, open or not, so it
passes the kind check unconditionally either way and both orderings reach
`require-open-handle`'s state check and raise the identical
`&uv-handle-closed` with the identical kind. Swapping the two outer checks
is only observable on an argument that fails BOTH checks at once, and
specifically fails them differently depending on order -- e.g. a CLOSED
handle of the WRONG kind (a closed timer), which would raise
`&uv-handle-closed('timer)` under the swapped order (state checked first,
inside `require-open-handle`, before the kind check ever runs) instead of
`&uv-invalid-argument('not-a-uv-stream)` under the real order (kind checked
first). No such row exists in `tests/test-stream.sps` or anywhere in the
tcp/echo/facade/pipe suites reached through the re-export -- the timer in
this suite is never closed, and every closed handle used against these
verbs already carries the correct kind. **Forward obligation:** a row that
closes a timer (or any non-stream handle) and then calls one of the four
verbs against it would catch this order swap by name; nothing currently in
`.superpowers/sdd/task-7-brief.md`'s Task 10 scope obviously adds one
either (a closed *process* handle, once one exists, would be the natural
future candidate, mirroring this exact gap). Reverted immediately after
capturing this; `make test` reconfirmed `ALL SUITES PASSED` at the GREEN
totals above before commit.

## Gate tail (post-revert, pre-commit)

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===            32
=== tests/test-facade.sps ===          49
=== tests/test-lifecycle.sps ===       64
=== tests/test-loop.sps ===           138
=== tests/test-native.sps ===         243
=== tests/test-pipe.sps ===            13
=== tests/test-shim-loading.sps ===    24
=== tests/test-stream.sps ===          10
=== tests/test-tcp.sps ===            168
=== tests/test-timer.sps ===          128
ALL SUITES PASSED
```

Identical to the Step-5 GREEN run; no probe mutation was left in the tree.

## Coverage notes

- The refuses-process row (THE SPEC §9.3's fourth kind) is explicitly
  deferred to Task 10's `tests/test-process.sps`, once `uv-spawn!` can
  construct a `uv-process-record` -- recorded there, not here, per the
  brief.
- Probe 2's forward obligation (above) is a genuine gap in today's suite,
  not merely a restated brief prediction: the brief's own phrasing assumed
  the closed-*pipe* row would catch the order swap, and it does not, for
  the structural reason traced above (a closed pipe already passes the kind
  check, so the swap is unobservable on it specifically). The gap closes
  the day a test closes a handle of the wrong kind before calling a stream
  verb on it.

## Task 10: probe 2 discharge (swapped kind/state order, closed timer)

Task 7's probe 2 is re-run against the completed Task 10 tree, which adds the
closed-timer row to `tests/test-stream.sps` -- the exact gap the forward
obligation named.

**Mutation**, in `src/libuv/stream.sls`:

```scheme
  (define (require-open-stream stream who)
    (require-open-handle stream who)           ; state check now FIRST
    (unless (uv-stream-record? stream)         ; kind check now SECOND
      (raise (make-uv-invalid-argument who 'not-a-uv-stream)))
    stream)
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-stream.sps
%%%% Starting test stream
  [informational] unconnected pipe write: EBADF
FAIL uv-write! on a CLOSED timer raises 'not-a-uv-stream, not &uv-handle-closed
# of expected passes      11
# of unexpected failures  1
```

**Result: FAILS BY NAME.** Under the swapped order, the closed timer hits
`require-open-handle` first, which raises `&uv-handle-closed` with kind
`'timer` before the kind check ever runs -- so the row's guard, which only
matches `uv-invalid-argument?` with reason `'not-a-uv-stream`, does not
match, and the assertion is scored FAIL. This is **probe 2 discharged**:
Task 7's forward obligation is closed. Reverted immediately; `diff` against
the pre-probe backup showed the file byte-identical; `tests/test-stream.sps`
alone reconfirmed 12 passes before continuing.
