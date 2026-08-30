# v0.5 Task 2 Mutation Log: OS socket buffer-size wrappers

Covers `src/libuv/handle.sls`'s four new public procedures
(`uv-send-buffer-size`, `uv-send-buffer-size!`, `uv-recv-buffer-size`,
`uv-recv-buffer-size!`) and their two shared helpers, `get-buffer-size!` and
`set-buffer-size!`. All edits were made directly in the repo's own
`src/libuv/handle.sls` (no scratch copy this time — each probe is a single,
small, easily-reverted edit); each mutation was applied, `make test` was
run, the predicted failure was confirmed by name, and the mutation was
reverted (`make test` back to `ALL SUITES PASSED`) before the next probe.
Probes A-E were recorded during the original Task 2 work; Probes F and G
were added in a follow-up review pass (Finding 1) to cover two assertions,
plus a sub-assertion of a third, that A-E left unwatched by any `src/`
mutation.

## Probe A: The zero seed

**Mutation:** in `get-buffer-size!`, inserted `(c-int-set! cell 1)`
immediately after the `alloc-zeroed`, before the `guard`:
```scheme
(let ((cell (alloc-zeroed (c-int-size))))
  (c-int-set! cell 1)                    ; MUTATION
  (guard (e (#t (free! cell) (raise e)))
    ...
```

**Build & test output** (`make test 2>&1 | grep -E "FAIL|of unexpected failures"`,
verbatim):
```
FAIL the facade's send-buffer getter and setter track at two points
FAIL the facade's receive-buffer getter and setter track at two points
# of unexpected failures  2
FAIL the send buffer tracks the value set, at two points
FAIL the receive buffer tracks independently of the send buffer
# of unexpected failures  2
```

**Result:** GREEN (failure detected), and exactly as predicted, though the
mechanism is a wiring flip, not a kernel clamp: `uv__socket_sockopt` (
`vendor/libuv/src/unix/core.c:255-261`) branches on `*value` — nonzero
takes the `setsockopt` arm, and that arm never writes back into `*value`.
The seeded `1` is nonzero, so `get-buffer-size!`'s call to the native
performs a *set* of `1` on the real socket and leaves the cell untouched;
`(c-int-ref cell)` then returns the literal `1` that was seeded, not
whatever `getsockopt` would have reported. Every getter call is thereby
pinned to return exactly `1` regardless of the socket's actual buffer size,
so neither the raw `test-flow.sps` rows nor the two facade rows can see the
value they just set. Both suites that exercise the getter through a real
read/write cycle failed, by name; nothing else did. Reverted; `make test`
returned to `ALL SUITES PASSED`.

---

## Probe B: The gate

**Mutation:** in `require-socket-handle`, changed `require-open-handle`
back to `require-handle`:
```scheme
(define (require-socket-handle handle who)
  (require-handle handle who)            ; MUTATION (was require-open-handle)
  ...
```

**Build & test output** (verbatim):
```
FAIL all four refuse a closing handle with &uv-handle-closed
# of unexpected failures  1
```

**Result:** GREEN (failure detected), exactly the one row named in the
brief. `require-handle` only checks that the handle is a live record (not
GC'd/discarded); it does not check the `'closing` vs `'open` state, so all
four wrappers silently succeeded against `bclosing`'s still-live pointer
instead of raising `&uv-handle-closed`. Reverted; `make test` returned to
`ALL SUITES PASSED`.

---

## Probe C: Swallow the native return code

**Mutation:** in both `get-buffer-size!` and `set-buffer-size!`, deleted
the `uv-check` wrapper, keeping the bare native call:
```scheme
;; before
(uv-check (native (handle-pointer handle who) cell) who)
;; after (both procedures)
(native (handle-pointer handle who) cell)
```

**Build & test output** (verbatim):
```
FAIL the send getter surfaces the native failure on a pipe with no fd
FAIL the send setter surfaces the native failure on a pipe with no fd
FAIL the receive getter surfaces the native failure on a pipe with no fd
FAIL the receive setter surfaces the native failure on a pipe with no fd
# of unexpected failures  4
```

**Result:** GREEN (failure detected), exactly the four rows named in the
brief, each reporting `'no-raise` (confirmed by re-running with the row
printed): with `uv-check` gone, `uv_send_buffer_size`/`uv_recv_buffer_size`
returning `-EBADF` for the unconnected pipe is never converted to an
`&uv-errno-error`, so all four wrappers return normally instead of raising.
Reverted; `make test` returned to `ALL SUITES PASSED`.

---

## Probe D: The kind allowlist

**Mutation:** in `require-socket-handle`, deleted the `memq` check:
```scheme
(define (require-socket-handle handle who)
  (require-open-handle handle who)
  handle)                                 ; MUTATION (memq check removed)
```

**Build & test output** (verbatim):
```
FAIL a timer is refused as a socket handle
# of unexpected failures  1
```

**Result:** GREEN (failure detected), exactly the one row named in the
brief. With the allowlist gone, a timer handle reaches
`uv-send-buffer-size-native` with a pointer to a `uv_timer_t`, not a
`uv_tcp_t`/`uv_pipe_t`; the row is what proves this kind check runs at all
rather than the operation happening to fail downstream in a way that also
raises. Reverted; `make test` returned to `ALL SUITES PASSED`.

---

## Probe E: Validate-after-allocate (expected NOT to fail `make test`)

**Mutation:** in `set-buffer-size!`, moved `require-buffer-size` below the
`alloc-zeroed`:
```scheme
;; before
(require-socket-handle handle who)
(require-buffer-size n who)
(let ((cell (alloc-zeroed (c-int-size))))
  (guard (e (#t (free! cell) (raise e)))
    ...
;; after
(require-socket-handle handle who)
(let ((cell (alloc-zeroed (c-int-size))))
  (require-buffer-size n who)             ; MUTATION: now inside the let,
  (guard (e (#t (free! cell) (raise e)))  ; but still OUTSIDE the guard
    ...
```

**Build & test output** (`make test 2>&1 | grep -E "FAIL|of unexpected failures|ALL SUITES PASSED"`,
verbatim):
```
ALL SUITES PASSED
```

**Result: expected asymmetry, not a failed probe.** No `FAIL` line anywhere
— every row that exercises `require-buffer-size`'s refusal (`"the send
setter refuses a non-positive size"`, `"the receive setter refuses a size
that does not fit an int"`) still sees the right `&uv-invalid-argument`
condition and still passes, because the *raise* is unaffected by the move —
only the *cell* is now allocated before the check that can abort the
call. When `require-buffer-size` raises, that raise happens outside the
`guard`'s dynamic extent (the `guard` form hasn't been entered yet), so
`free!` is never called on `cell` and it leaks exactly once per refused
call. This is invisible to a plain build/run because Chez's own heap
absorbs one leaked malloc'd `int` per test row with no observable symptom.

**`make test-memory` (Darwin, ASan), with the mutation still applied:**
all sixteen suites (`test-flow.sps` at 18 expected passes) ran and passed,
exit code 0 for the suite loop. Grepped the full output for
`definitely lost:`, `Invalid read`, and `Invalid write`: zero matches. This
is the *stronger* form of the expected asymmetry — the brief predicted the
leak is caught by Valgrind "on the Linux leg"; on this Darwin/arm64
development machine `make test-memory` runs under ASan, and ADR-0003 records
that the ASan leg makes no leak claim at all (it is enabled for
addressability checking — invalid read/write, use-after-free — not for leak
detection). So on this host **neither** `make test` **nor** `make
test-memory` observes Probe E's leak; only a Linux CI run under Valgrind
(`--errors-for-leak-kinds=definite`) would report a `definitely lost:` line
for it. This is exactly the justification the brief gives for the four
EBADF native-failure rows added in this task: they are what gives the
Valgrind lane on Linux CI a *reachable* failure path through
`set-buffer-size!` (a refused, non-positive size on `btcp`) to actually
walk and catch this class of bug — this repo's local ASan run structurally
cannot.

Reverted (`require-buffer-size` moved back above the `let`); `make test`
returned to `ALL SUITES PASSED`.

---

## Probe F: Weaken the bounds check (added in review follow-up)

Probes A-E left three assertions with no `src/` mutation watching them:
`"the send setter refuses a non-positive size"`, `"the receive setter
refuses a size that does not fit an int"`, and the `send-unmoved`
sub-assertion inside `"the receive buffer tracks independently of the send
buffer"`. Probe E moves `require-buffer-size`'s position but does not test
the check's correctness, and by design produces no plain-build failure.
Probes F and G close that gap.

**Mutation:** in `require-buffer-size`, changed `(positive? n)` to
`(>= n 0)`:
```scheme
;; before
(unless (and (integer? n) (exact? n) (positive? n) (< n 2147483648))
;; after
(unless (and (integer? n) (exact? n) (>= n 0) (< n 2147483648))    ; MUTATION
```
This matters specifically because `uv__socket_sockopt` treats `*value == 0`
as a **get**, not an error (`vendor/libuv/src/unix/core.c:255-261`), so
`n = 0` would silently perform a read instead of raising.

**Build & test output** (`make test 2>&1 | grep -E "FAIL|of unexpected failures"`,
verbatim):
```
FAIL the send setter refuses a non-positive size
# of unexpected failures  1
SUITE FAILED
```

**Result:** GREEN (failure detected), exactly the row named in the brief.
With `n = 0` no longer rejected, `uv-send-buffer-size! btcp 0` passes
`require-buffer-size` and reaches `set-buffer-size!`'s `c-int-set! cell 0`
followed by the native call — which, per the `*value == 0` branch above,
turns the intended *set* into a silent *get*, so the guard's expected
`&uv-invalid-argument` never raises and the row's `'no-raise` sentinel is
what's compared against the expected condition list. Reverted (`(positive?
n)` restored); `make test` returned to `ALL SUITES PASSED`.

---

## Probe G: Cross-wire the receive setter (added in review follow-up)

**Mutation:** in `uv-recv-buffer-size!`, passed `uv-send-buffer-size-native`
instead of `uv-recv-buffer-size-native`:
```scheme
;; before
(define (uv-recv-buffer-size! handle n)
  (set-buffer-size! uv-recv-buffer-size-native handle n 'uv-recv-buffer-size!))
;; after
(define (uv-recv-buffer-size! handle n)
  (set-buffer-size! uv-send-buffer-size-native handle n 'uv-recv-buffer-size!)) ; MUTATION
```

**Build & test output** (`make test 2>&1 | grep -E "FAIL|of unexpected failures"`,
verbatim):
```
FAIL the facade's receive-buffer getter and setter track at two points
# of unexpected failures  1
FAIL the receive buffer tracks independently of the send buffer
# of unexpected failures  1
SUITE FAILED
```

**Result:** GREEN (failure detected). The predicted row (`"the receive
buffer tracks independently of the send buffer"`) failed as expected — with
the setter cross-wired to `uv_send_buffer_size`, `uv-recv-buffer-size!`
resizes SO_SNDBUF instead of SO_RCVBUF, so `recv-high` no longer exceeds
`recv-low` (`tracks-upward` fails) and, separately, the real SO_SNDBUF value
now *does* move underneath the unrelated `send-unmoved` check. `make test`
also surfaced a second, unpredicted-by-name-in-the-brief-but-expected-by-
construction failure in `test-facade.sps` (`"the facade's receive-buffer
getter and setter track at two points"`), which exercises the same
`uv-recv-buffer-size!` through the facade's own connected pair — confirming
this mutation is caught by every suite that loads `(libuv handle)`, not
`test-flow.sps` alone, which is why the brief's verification pass calls for
the full `make test` rather than a single suite. Reverted
(`uv-recv-buffer-size-native` restored); `make test` returned to `ALL
SUITES PASSED`.

---

## `make test-memory` (Darwin, ASan), clean tree

All sixteen suites completed with no `FAIL` lines, exit code 0. Grepped the
full output for `definitely lost:`, `Invalid read`, `Invalid write`: zero
matches. Per ADR-0003 the Linux leg is the sole memory-leak gate; this
Darwin run is ASan and makes no leak claim, consistent with the brief and
with Task 1's mutation log.

## Final state

All seven mutations (A-E from the original task, F and G from the review
follow-up) reverted; `git diff --stat -- src/libuv/handle.sls` shows only
the Task 2 feature diff plus the review's Finding 2 comment fix, no mutation
residue. `make test` after the last revert: `ALL SUITES PASSED`.
