# v0.5 Task 3 Mutation Log: `uv-stream-write-queue-size`

Covers `src/libuv/stream.sls`'s new public procedure
`uv-stream-write-queue-size` and its native binding
`uv-stream-get-write-queue-size-native` in
`src/libuv/private/native.sls`. All edits were made directly in the repo's
own files (each probe is a single, small, easily-reverted edit); each
mutation was applied, `make test` was run, the predicted failure was
confirmed by name, the underlying mechanism was verified by a direct,
throwaway probe program against the compiled library (not inferred from
reading the code — Task 2's log records three mechanism narratives that
were wrong on first telling and only caught this way), and the mutation
was reverted (`make test` back to `ALL SUITES PASSED`, `git diff --stat --
src/` matching only the feature diff) before the next probe.

## Probe A: Constant zero

**Mutation:** in `src/libuv/private/native.sls`, replaced the
`foreign-procedure` binding with a stub returning `0`:
```scheme
;; before
(define uv-stream-get-write-queue-size-native
  (foreign-procedure "uv_stream_get_write_queue_size" (uptr) size_t))
;; after
(define (uv-stream-get-write-queue-size-native ptr) 0)   ; MUTATION A
```

**Build & test output** (`make test 2>&1 | grep -E "FAIL|of unexpected
failures|SUITE FAILED"`, verbatim):
```
FAIL the write queue goes positive against an unreading peer
FAIL an idle stream on the same loop reads zero while the other is congested
# of unexpected failures  2
SUITE FAILED
```

**Result:** GREEN (failure detected), exactly the two rows predicted by
the brief; the drain row ("the queue falls to zero AND every write
completed once the peer reads") did NOT fail, also exactly as predicted.

**Mechanism, verified by direct probe** (a standalone `chez --program`
run reproducing the congestion fixture's push loop against the mutated
library, printing the loop's actual return value): with the native
stubbed to always answer `0`, `(uv-stream-write-queue-size cclient)` never
satisfies `positive?` on any of the 64 attempts, so the push loop runs out
its full iteration cap and `congested` evaluates to the literal sentinel
`'gauge-never-went-positive` — confirmed directly as:
```
(congested gauge-never-went-positive)
```
That is compared against the row's expected `'positive` and fails. The
idle-stream row's `congested-positive` half fails for the same reason
(`(uv-stream-write-queue-size cclient)` is `0`, never positive); its
`idle-zero` half still passes coincidentally, since the idle stream's real
queue is genuinely `0` too and the stub cannot be distinguished from the
real answer on that side. The drain row passes because its predicate
`(zero? (uv-stream-write-queue-size cclient))` is unconditionally true
under this stub from the very first check, and the writes still complete
for real (the mutation only touches the gauge, not the write path), so
`completions = submissions` holds independently. This is exactly why the
brief requires the drain row to assert both halves: a gauge stubbed to `0`
would otherwise make this row pass trivially, which it does here for the
`satisfied` half but is masked by the OTHER two rows already catching the
stub. Reverted; `make test` returned to `ALL SUITES PASSED`.

---

## Probe B: Constant non-zero

**Mutation:** in `src/libuv/private/native.sls`:
```scheme
(define (uv-stream-get-write-queue-size-native ptr) 4096)   ; MUTATION B
```

**Build & test output** (verbatim):
```
FAIL the facade's write-queue-size answers zero on an idle stream
# of unexpected failures  1
FAIL an idle stream on the same loop reads zero while the other is congested
FAIL the queue falls to zero AND every write completed once the peer reads
# of unexpected failures  2
SUITE FAILED
```

**Result:** GREEN (failure detected), exactly the three rows predicted by
the brief. Note this cuts across two suites (`test-facade.sps` reports its
own `# of unexpected failures  1` before `test-flow.sps`'s `2`, since each
suite is a separate SRFI-64 run) — both `# of unexpected failures` lines
are genuine, not a duplicate count.

**Mechanism, verified by direct probe:** a standalone reproduction of the
fixture printed the push loop's actual state under this mutation:
```
(congested 4096 idle 4096)
(drain-result iterations-exhausted completions 1 submissions 1 gauge-now 4096)
```
Two things here are less obvious than "the gauge is wrong" and are worth
recording exactly because of Task 2's lesson about verifying mechanism
rather than assuming it:

1. **Only ONE write is ever submitted**, not 64. The push loop's stub
   sample after the very first `uv-write!` already reads `4096`, which
   satisfies `positive?` immediately, so `congested` is bound to `4096` on
   the very first iteration and the loop never runs again. The "goes
   positive" row therefore still PASSES under this mutation (correctly —
   the brief does not list it as an expected failure): a constant
   non-zero stub is indistinguishable from a real positive reading on
   that row alone, by construction.
2. **The idle-stream row fails on its `idle-zero` half**, because the
   stub answers `4096` for `cidle` too, regardless of stream identity —
   `(uv-stream-write-queue-size cidle)` is `4096`, not `0`, so the pair
   reads `(congested-positive idle-nonzero)` against the expected
   `(congested-positive idle-zero)`. This is THE row the brief calls out
   as "the per-stream discriminator," and it is exactly what catches a
   binding that answers the same constant regardless of which stream
   pointer it was given.
3. **The drain row fails on `run-until/ticking`'s return value, not on
   completions.** Because only one 65536-byte write was ever submitted
   (point 1), the real kernel drains it well within the 20000-iteration
   cap and `completions` does reach `submissions` (`1 = 1`, confirmed
   above) — the `all-completed` half of the row is satisfied. But
   `(zero? (uv-stream-write-queue-size cclient))` can never hold, since
   the stub answers `4096` unconditionally forever, so `run-until/ticking`
   burns its full cap and returns `'iterations-exhausted` instead of
   `'satisfied`. The row still fails as a whole (`test-equal` compares the
   two-element list atomically), but it fails through the FIRST element,
   not the second — a distinction Task 2's Probe G log flags as easy to
   get backwards when a list-shaped row's `FAIL` line does not say which
   element differed. Reverted; `make test` returned to `ALL SUITES
   PASSED`.

---

## Probe C: The gate

**Mutation:** in `src/libuv/stream.sls`, deleted the `require-open-stream`
call from `uv-stream-write-queue-size`:
```scheme
;; before
(define (uv-stream-write-queue-size stream)
  (require-open-stream stream 'uv-stream-write-queue-size)
  (uv-stream-get-write-queue-size-native
   (handle-pointer stream 'uv-stream-write-queue-size)))
;; after
(define (uv-stream-write-queue-size stream)
  ;; MUTATION C: require-open-stream deleted
  (uv-stream-get-write-queue-size-native
   (handle-pointer stream 'uv-stream-write-queue-size)))
```

**Build & test output** (verbatim):
```
FAIL a closing stream refuses the gauge with &uv-handle-closed
# of unexpected failures  1
SUITE FAILED
```

**Result:** GREEN (failure detected), exactly the one row named in the
brief, and no other row anywhere in the suite.

**Mechanism, verified by direct probe:** a standalone probe built a TCP
handle, bound it, called `uv-close!` on it (without ever calling
`uv-run`), printed `(uv-handle-state doomed)`, and then called the mutated
`uv-stream-write-queue-size` under a `guard`:
```
(state closing)
(result 0)
```
This confirms the brief's claim precisely: after `uv-close!` returns, the
handle's state is `'closing` (not `'closed` — the close dispatcher that
would transition it to `'closed` and zero its pointer only runs on a
later `uv-run`, which this test never calls), and with the gate removed
the call does not raise at all. `handle-pointer` only refuses a NULL/freed
pointer; a `'closing` handle's pointer is still live, so
`uv-stream-get-write-queue-size-native` runs against a real, still-valid
`uv_tcp_t` and returns a genuine (if uninteresting) `size_t` value — `0`
in this case, since nothing was ever written to `doomed`. The row's guard
therefore falls through to `'no-raise` instead of `'closed`, which is
compared against the expected `'closed` and fails. This is the "silent"
failure mode the brief warns about: the missing gate does not crash or
return a sentinel, it returns a plausible-looking number, which is
exactly why the fixture targets a CLOSING stream specifically rather than
a fully closed one — on a fully closed handle, `handle-pointer` itself
would already refuse the zeroed pointer with a DIFFERENT condition
(`&uv-invalid-argument 'null-handle-pointer`, `handles.sls:471-475`),
which would surface a real raise but the WRONG one, rather than no raise
at all — so it would not discriminate a missing gate from a present one
the same way. Reverted; `make test` returned to `ALL SUITES PASSED`,
`git diff --stat -- src/` matching only the feature diff.

---

## `make test-memory` (Darwin, ASan), clean tree

All sixteen suites completed with no `FAIL` lines, exit code 0
(`test-flow.sps` at 23 expected passes, `test-facade.sps` at 65). Grepped
the full output for `definitely lost:`, `Invalid read`, `Invalid write`,
`ERROR: AddressSanitizer`, `LeakSanitizer`: zero matches, aside from this
run's own informational banner line ("macOS: ASan preload only;
LeakSanitizer is unsupported on arm64"). Per ADR-0003 and Task 1/Task 2's
logs, the Linux leg under Valgrind is the sole memory-leak gate; this
Darwin/ASan run makes no leak claim and is checked here only for
addressability (invalid read/write, use-after-free), consistent with
prior tasks.

## Final state

All three mutations (A, B, C) reverted; `git diff --stat -- src/` and
`git diff --stat -- tests/` show only this task's feature diff, no
mutation residue. `tests/test-flow.sps` carries 23 rows (18 + 5, matching
the brief's expectation); `tests/test-facade.sps` gained its one row (64 →
65). `make test` after the last revert: `ALL SUITES PASSED`.
