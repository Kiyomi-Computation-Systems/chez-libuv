# v0.5 Task 1 Mutation Log: forward guards (default read-buffer pin + cross-stream isolation)

Covers `tests/test-tcp.sps` (the size-less `uv-read-start!` default-buffer
pin) and `tests/test-flow.sps` (the four-reader cross-stream isolation
suite). Both suites were run unmodified against unchanged `src/`, then each
targeted mutation below was applied, the full suite re-run, the predicted
failure confirmed by name, and the mutation reverted before the next step.

## Probe 1: Shift the default read-buffer size by one byte

**Mutation:** `src/libuv/stream.sls`, `default-read-buffer-size`:
`(define default-read-buffer-size 65536)` -> `(define
default-read-buffer-size 65535)`.

**Build & test output** (`make test 2>&1 | grep -E '^FAIL|unexpected
failures'`, verbatim, no other lines matched):
```
FAIL a size-less read-start allocates default-read-buffer-size
# of unexpected failures  1
```

**Result:** GREEN (failure detected). Exactly the one row named in the
brief failed, in exactly one suite (`test-tcp`); no other suite reported an
unexpected failure. Reverted (`cp /tmp/stream.sls.bak
src/libuv/stream.sls`); `make test` returned to `ALL SUITES PASSED`.

---

## Probe 2: Shift `alloc-dispatch`'s answer one byte past the buffer's base

**Mutation:** `src/libuv/private/handles.sls`, `alloc-dispatch`'s stream
arm:
```scheme
;; before
(uv-buf-set! buf-ptr (stream-read-buf handle) (stream-read-buf-len handle))
;; after
;; MUTATION: answer one byte past the base.
(uv-buf-set! buf-ptr
             (+ (stream-read-buf handle) 1)
             (- (stream-read-buf-len handle) 1))
```
Total, not a raise: `alloc-dispatch` is infallible by requirement
(`handles.sls:846-858`, guarded by its own named row in
`test-tcp.sps:1389-1394`), so the mutation still hands back a valid pointer
and length — it only reads from the wrong address, one byte into the
buffer's tail padding, dropping the true buffer's last byte on every read.

**Correction (fix report Task 1 review, see `.superpowers/sdd/task-1-report.md`
`## Fix 1`):** the three index-keyed `survivor N received exactly its own
bytes` rows below were replaced by one row, `"each survivor received exactly
one complete, uncorrupted payload"`, because accept order is not
contractually `uv-tcp-connect!` call order — `peers[i]` was never guaranteed
to be `cli[i]`'s connection, so the index-keyed comparison could spuriously
fail (or spuriously pass under a corrupting mutation, via permutation) for
reasons unrelated to any regression. `test-flow.sps`'s row count dropped
from 10 to 8. The mutation was re-run against the corrected suite below;
output re-captured verbatim.

**Build & test output** (`make test 2>&1 | grep -E '^FAIL|unexpected
failures|^==='`, verbatim):
```
=== tests/test-echo.sps ===
FAIL client 0 received back exactly the bytes it sent
FAIL client 1 received back exactly the bytes it sent
FAIL client 2 received back exactly the bytes it sent
FAIL client 3 received back exactly the bytes it sent
FAIL client 4 received back exactly the bytes it sent
FAIL client 5 received back exactly the bytes it sent
FAIL client 6 received back exactly the bytes it sent
FAIL client 7 received back exactly the bytes it sent
# of unexpected failures  8
=== tests/test-facade.sps ===
FAIL uv-read-start! is re-exported and delivered the payload to the peer
# of unexpected failures  1
=== tests/test-flow.sps ===
FAIL each survivor received exactly one complete, uncorrupted payload
# of unexpected failures  1
=== tests/test-process.sps ===
FAIL argv[0], argv[1], env, and cwd all arrived as written
FAIL omitted env inherits the parent's
FAIL empty env: the parent's variable did not cross
FAIL payload survived byte-for-byte
FAIL duplex payload intact
FAIL
FAIL
# of unexpected failures  7
=== tests/test-signal.sps ===
FAIL the child armed and acked READY
FAIL the child acked delivery (GOT1, from inside the callback)
FAIL the child acked disarm (DISARMED, from a later dispatch)
FAIL the ack transcript is exactly READY/GOT1/DISARMED
# of unexpected failures  4
=== tests/test-tcp.sps ===
FAIL the bytes the peer read are the bytes the client wrote
FAIL the alloc dispatcher hands libuv the handle's own buffer, at its full length
FAIL a 1 MiB transfer in 64 KiB chunks arrives byte for byte
FAIL restarting the read delivers exactly the bytes that were held back
# of unexpected failures  4
```
(`test-addrinfo`, `test-conditions`, `test-dns`, `test-lifecycle`,
`test-loop`, `test-native`, `test-pipe`, `test-shim-loading`,
`test-stream`, `test-timer` produced no `FAIL` lines and are omitted; their
`===` headers were also grepped and confirmed clean.)
`make test` exits with `SUITE FAILED` / `make: *** [test] Error 1`.

**Result:** GREEN (failure detected), through the asserted property in
every case: every failing row is a byte-content or read-path assertion, and
every count-based or seed/gate row in `test-flow.sps` ("seed: every client
connected and was accepted", "seed: the survivors' payloads are pairwise
distinct", "gate: the closed reader reached 'closed before survivors are
written to", "seed: the closing reader received the trigger write before
closing", "every survivor received its full payload", "the closed reader
received nothing further", "counters all zero after teardown") stayed
green, as predicted — count-based assertions do not see a one-byte content
shift. Reverted (`cp /tmp/handles.sls.bak
src/libuv/private/handles.sls`); `make test` returned to `ALL SUITES
PASSED`.

**Blast radius wider than the brief's specific enumeration — noted per the
task's "trust the source over the brief" instruction.** The brief predicted
"the three `survivor N` rows, plus `test-echo.sps`'s byte-equality rows and
`test-tcp.sps`'s read-path rows." All of those failed as predicted, but so
did `test-facade.sps` (one row), `test-process.sps` (seven rows), and
`test-signal.sps` (four rows) — none of which the brief's enumeration
named. This is not a sign the mutation was mis-scoped: `alloc-dispatch`
guards `uv-stream-record?`, not `uv-tcp-record?` (ADR-0014, comment at
`handles.sls` above the dispatcher), because tcp and pipe share the whole
read path. `test-process.sps` and `test-signal.sps` both move bytes over
pipes (child stdio, ack transcripts), so a one-byte shift in the shared
read path corrupts their payloads too, and `test-facade.sps` asserts the
facade's own re-exported `uv-read-start!` delivers a payload byte-for-byte.
The brief's text acknowledged "a deliberately wide blast radius" without
enumerating these three suites; the actual observed radius is every suite
that reads bytes over a stream handle of either kind, which is wider but
consistent with the code the mutation touches. No test or mutation was
changed to narrow this — the real output is recorded as observed.

---

## Uncovered, and why

**`"the closed reader received nothing further"` (test-flow.sps) is an
explicitly uncovered property.** Neither of the two probes above moves it:
Probe 1 (the buffer-size pin) has no bearing on byte content at all, and
Probe 2 (the alloc-dispatch base shift) — the one mutation in this task
that touches the read path the row depends on — left it green, because the
row is a *count* comparison (`closed-deliveries-at-gate` vs.
`(collector-count (vector-ref cols 0))` after the gate), and reader 0's
read callback is only ever invoked once more after the gate opens if
libuv's read machinery still dispatches to it at all. In this binding it
structurally cannot: `close-dispatch` deregisters the handle from the
pointer->record registry on the same loop iteration `uv-close!`'s
`uv_close` callback fires, and every dispatcher (`alloc-dispatch`,
`read-dispatch`) resolves its handle through that registry
(`registry-ref`) before doing anything else. Once the gate condition
(`(eq? 'closed (uv-handle-state (vector-ref peers 0)))`) is satisfied, the
handle is already deregistered, so no read dispatch — mutated or not — can
reach `(vector-ref cols 0)` again. The row is real (it would catch a
regression that delivered post-close reads through some OTHER path, e.g. a
stale callback closure invoked directly rather than through libuv), but no
`src/` mutation available to Task 1 exercises the property it names,
because the property's guarantee is structural (the registry lookup
gating every dispatcher) rather than a single conditional this task's two
probes touch. Per AGENTS.md: "If no mutation can break the assertion... write
down in the mutation log that the property is uncovered and why." Recorded
here rather than deleted or backed by a fabricated mutation, as instructed.

## `make test-memory` (Darwin, ASan)

`make test-memory 2>&1`: all fifteen suites (`test-flow.sps` at 10 expected
passes) completed, exit code 0. No `definitely lost:` line and no `Invalid
read`/`Invalid write` marker line anywhere in the output. Per ADR-0003 the
Linux leg is the sole memory-leak gate; this Darwin run is ASan and makes
no leak claim, consistent with the brief.

## Final state

Both mutations reverted; `git diff --stat -- src/` is empty. `make test`
after each revert: `ALL SUITES PASSED`.
