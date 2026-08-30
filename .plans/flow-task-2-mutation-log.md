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
mutation. A second review pass (Fix 2) proved by direct experiment that
Probe G's `send-unmoved` sub-assertion was never actually exercised under
the constants `test-flow.sps` used at the time -- `tests/test-flow.sps`'s
recv-buffer constants were widened to make it detectable, Probe G was
re-run against the corrected test, and Probe H was added for a fourth
previously-unwatched assertion (the receive setter's upper-bound refusal).

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

## Probe G: Cross-wire the receive setter (added in review follow-up;
narrative corrected in Fix 2 — the original text below overstated what this
probe had proven; read the whole entry, not just the first run)

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

**First recorded run (Fix 1), under `test-flow.sps`'s ORIGINAL constants**
(the recv section then used the same `8192`/`262144` the send section uses)
(`make test 2>&1 | grep -E "FAIL|of unexpected failures"`, verbatim):
```
FAIL the facade's receive-buffer getter and setter track at two points
# of unexpected failures  1
FAIL the receive buffer tracks independently of the send buffer
# of unexpected failures  1
SUITE FAILED
```
This was logged at the time as proof that the row's `send-unmoved` element
was watched. It is not: `test-equal` compares the whole two-element list
`'(tracks-upward send-unmoved)` as one unit, so a `FAIL` here only proves
*some* element differed from expected — not which one. Evaluating the row's
own expressions directly (`chez --program`, same libraries, same handle,
same call sequence, mutation still applied) shows which:
```
(send-low 8192 send-high 262144)
(recv-low 131072 recv-high 131072)
(row-result (did-not-track send-unmoved) expected (tracks-upward send-unmoved))
```
`row-result`'s second element already reads `send-unmoved` — matching what
`test-equal` expects. Only the first element (`did-not-track` vs. expected
`tracks-upward`) differs; the row fails entirely on `tracks-upward` and
`send-unmoved` contributes nothing. The mechanism: `setsockopt` is
last-write-wins with no history dependence, and the recv section's mutated
calls write SO_SNDBUF with the SAME two values (`8192` then `262144`) the
send section already used, landing SO_SNDBUF back on exactly `send-high`
(`262144`) by coincidence of shared constants — not because the cross-wire
was caught. `send-unmoved` is structurally unfalsifiable as long as both
sections share constants, exactly as the reviewer identified.

**Fix applied (Fix 2):** `tests/test-flow.sps`'s recv section constants
changed from `8192`/`262144` to `16384`/`131072`, distinct from the send
section's. Verified first that the recv `tracks-upward` element still holds
on this host (Darwin/arm64) with the new constants: a raw
`setsockopt`/`getsockopt` probe (`SO_RCVBUF` set to `16384` then `131072`)
read back exactly the requested values, no kernel doubling or clamping on
this platform, so `16384 -> 131072` is still strictly increasing here; a
clean-tree `make test` after the constant change alone stayed `ALL SUITES
PASSED` with `test-flow.sps` still reporting 18 expected passes.

**Second run, same mutation, against the corrected constants** (`make test
2>&1 | grep -E "FAIL|of unexpected failures"`, verbatim):
```
FAIL the facade's receive-buffer getter and setter track at two points
# of unexpected failures  1
FAIL the receive buffer tracks independently of the send buffer
# of unexpected failures  1
SUITE FAILED
```
Same two `FAIL` lines by name as before (expected — the mutation and the
row names did not change), but the element-level picture is now different:
```
(send-low 8192 send-high 262144)
(recv-low 131072 recv-high 131072)
(row-result (did-not-track send-moved) expected (tracks-upward send-unmoved))
```
With `16384`/`131072` no longer equal to `send-high` (`262144`), the
cross-wired writes leave real SO_SNDBUF at `131072` when the recv section
finishes, which no longer equals `send-high` — `send-unmoved` now correctly
reads `send-moved`. **Both** elements of `row-result` now disagree with
expected: `tracks-upward` still fails (see aside below for why) and
`send-unmoved` fails for the first time. As of this fix, Probe G's row is
genuinely watched through `send-unmoved`, not only through `tracks-upward`.

**Aside, for accuracy, not a defect:** on this Darwin host `recv-low` and
`recv-high` both read back `131072` under the mutation — not from clamping,
but because the mutated setter never touches real SO_RCVBUF at all (both
calls land on SO_SNDBUF instead), so the getter reports this socket's
untouched default the whole run, and that default happens to equal
`131072`, one of the two new recv constants (confirmed with a standalone
`getsockopt(SO_RCVBUF)` probe on a fresh socket). This is coincidental and
does not affect the unmutated code path: there the setter genuinely writes
SO_RCVBUF to `16384` then `131072`, so `tracks-upward` passes on real,
actively-set values, as the clean post-constant-change `make test` run
above confirms. Under Probe G's mutation specifically, `recv-low` and
`recv-high` would read as equal — and `tracks-upward` would fail — for any
pair of distinct recv constants, since the real receive buffer is pinned at
whatever its untouched default is; `131072` matching one of the chosen
constants is a coincidence of this host's default, not the reason the
assertion fails.

`test-facade.sps`'s row (`"the facade's receive-buffer getter and setter
track at two points"`) failed both times, unaffected by either constant
set, for a different and simpler reason — see the `test-facade.sps`
decision note in Fix 2 of `.superpowers/sdd/task-2-report.md`.

Reverted (`uv-recv-buffer-size-native` restored) after each run above;
`make test` returned to `ALL SUITES PASSED` and `git diff --stat -- src/`
was empty each time.

---

## Probe H: Weaken the upper-bound check (added in Fix 2)

Row 4, `"the receive setter refuses a size that does not fit an int"`, had
no `src/` mutation watching it: Probe F only weakens `(positive? n)`;
nothing in Probes A-G exercises `require-buffer-size`'s upper bound,
`(< n 2147483648)`.

**Mutation:** in `require-buffer-size`, changed `(< n 2147483648)` to
`(<= n 2147483648)`:
```scheme
;; before
(unless (and (integer? n) (exact? n) (positive? n) (< n 2147483648))
;; after
(unless (and (integer? n) (exact? n) (positive? n) (<= n 2147483648))    ; MUTATION
```
`n = 2147483648` (2^31, one past the largest signed 32-bit int) now passes
validation and reaches `set-buffer-size!`'s `(c-int-set! cell n)`.

**Build & test output** (`make test 2>&1 | grep -E "FAIL|of unexpected failures"`,
verbatim):
```
FAIL the receive setter refuses a size that does not fit an int
# of unexpected failures  1
SUITE FAILED
```

**Result:** GREEN (failure detected), exactly the row named in the brief,
and no other suite's row — this assertion is one `test-flow.sps` has no
facade-level counterpart for.

**Narrative corrected (Fix 3):** the original text here, and the comment it
was copied from above `require-buffer-size` in `src/libuv/handle.sls`, both
claimed `c-int-set!` raises a raw Chez exception for a value that does not
fit an `int`. A reviewer tested `c-int-set!` directly against the compiled
library and found this false: `(c-int-set! cell 2147483648)` does not raise
at all — it silently truncates via two's-complement wraparound, and
`(c-int-ref cell)` afterward reads back `-2147483648`. That negative value
is what actually reaches `uv_recv_buffer_size`; its `setsockopt` rejects it
with `EINVAL` (`rc = -22`), and `uv-check` converts *that* into
`&uv-errno-error` — a member of this binding's own condition hierarchy, and
specifically not `&uv-invalid-argument`. That is why the row's guard falls
through to its `'wrong-condition` arm: the raised condition is real and is
what the pasted `FAIL` output above correctly recorded, but it is an
`&uv-errno-error` from the OS's rejection, not a raw Chez exception from
`foreign-set!`. Confusingly, `&uv-errno-error`'s message text reads
literally `"invalid argument"` (libuv's `uv_strerror(UV_EINVAL)`), which is
almost certainly what produced the original "raw Chez exception" misreading
in the first place. The reviewer's mechanism was verified here by direct
test against the compiled library, not inferred from the code — the same
standard Probe A's "kernel clamp" and Probe G's "SO_SNDBUF now moves" were
both held to and both failed on inspection; this is the third mechanism
narrative in this task to be wrong on first telling and only caught by
running the actual check, which is worth noting as a pattern for future
probes in this log. Reverted (`(< n 2147483648)` restored); `make test`
returned to `ALL SUITES PASSED`, `git diff --stat -- src/` empty.

---

## `make test-memory` (Darwin, ASan), clean tree

All sixteen suites completed with no `FAIL` lines, exit code 0. Grepped the
full output for `definitely lost:`, `Invalid read`, `Invalid write`: zero
matches. Per ADR-0003 the Linux leg is the sole memory-leak gate; this
Darwin run is ASan and makes no leak claim, consistent with the brief and
with Task 1's mutation log.

## Final state

All eight mutations (A-E from the original task, F and G from the first
review follow-up, H from the second) reverted; `git diff --stat --
src/libuv/handle.sls` shows only the Task 2 feature diff plus the first
review's Finding 2 comment fix, no mutation residue. `tests/test-flow.sps`
carries Fix 2's recv-buffer constant change (`8192`/`262144` →
`16384`/`131072`) but is unchanged at 18 rows. `make test` after the last
revert: `ALL SUITES PASSED`.
