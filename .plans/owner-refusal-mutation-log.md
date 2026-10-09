# What &uv-wrong-thread names (#102): evidence and mutation log

2026-10-09. Every verb that checks its loop's owner checks it in its step
and raises `&uv-wrong-thread` once the step is over. The step answered a
bare `'wrong-thread`, and the verb read the loop's owner again to build
the condition, so a loop handed on in between was named in place of the
owner the step had compared against. Now an owner check answers an
`owner-mismatch` holding the owner it compared against and the caller,
and the refusal is built from that (ADR-0019, decision 2's amendment of
2026-10-09). The sweep is in `tests/test-owner-refusal.sps`.

## The hand-back sweep

Each run takes a loop of its own and makes on it what the verb needs. It
runs the verb in an engine at fuel 1, 2, …. At the first expiry the
scheduler hands the loop to another thread, resumes the verb with one
tick, and at the second expiry hands the loop back to this thread. An
expiry that comes due inside a step waits for the step's end. So one
tick puts the hand-back at the earliest point an expiry can come after
the step: a 2-D probe on main over every (first expiry, gap) pair found
`uv-tcp-bind!`'s defect on one anti-diagonal (first + gap = 26, first ≥
11), which a gap of one reaches at first = 25.

A refused run must name the other thread as `expected` and this one as
`actual`. A run may also return, having made its call before the first
handoff or after the hand-back.

## On main (ad3bb47)

The suite was written first and run against main's verbs. The fuel maps
were identical on macOS (arm64) and glibc 2.36 (Debian 12, aarch64, the
Valgrind image). Fifteen verbs were refused naming this thread as both
`expected` and `actual` (`(wrong-thread who 0 0)`, the main thread's id
being 0), each at the last fuel before its step:

| Verb | refused naming itself at fuel |
|---|---|
| `uv-accept!` | 15 |
| `uv-tcp-bind!` | 24 |
| `uv-tcp-getsockname-port`, `uv-tcp-sockname-address`, `uv-tcp-peer-address` | 14 |
| `uv-send-buffer-size`, `uv-recv-buffer-size` | 9 |
| `uv-send-buffer-size!`, `uv-recv-buffer-size!` | 10 |
| `uv-tcp-connect!` | 26 |
| `uv-signal-start!`, `uv-signal-start-oneshot!` | 12 |
| `uv-write!` | 16 |
| `uv-write*!` | 22 |
| `uv-shutdown!` | 11 |

Each was refused by its step, and the hand-back came in `step-refusal`,
before the second read. The other 24 verbs, swept in 25 sweeps
(`uv-tcp-keepalive!` has two forms), named the right owner in every run,
for one of two reasons. A probe told them apart: in a scratch copy
of the fix, whose steps and fuel maps are main's, `step-refusal` named
every refusal it built from an owner-mismatch `STEP` instead of the verb,
and the sweep listed which verbs' steps refused.

- **Refused by their step, with no trap before the second read** (10):
  the five constructors (fuel 14–18), `uv-update-time!` (7), `uv-getaddrinfo!`
  (31), `uv-getnameinfo!` (38), `uv-cancel!` (9) and `uv-spawn!` (68). On
  main no expiry came between their step and the second read.
- **Never refused by their step** (14): the five timer verbs,
  `uv-listen!`, `uv-tcp-nodelay!`, `uv-tcp-keepalive!`, `uv-signal-stop!`,
  both read verbs, `uv-stream-write-queue-size`, `uv-process-kill!` and
  `uv-process-pid`. Nothing between their entry check and their step can
  trap, so the entry check, which builds its condition from what it
  compared, refused every run stopped before the step. #109's amendment
  measured the same for four of them.

The probe's step refusals were the fifteen above and these ten, 25 verbs
in all. For all 24 without the defect, only another thread's claim could
open the window, and no sweep runs one.

The suite's three sweep rows on main: the bad-run row FAILED with the
fifteen runs above; the reach row (every sweep refused its verb in some
run and ran it to the end) and the children row passed. Run twice; the
same both times.

## On the fix

The same fuel maps on both platforms, and every refusal names the other
thread and this one. The suite passed 10 runs of 10 on macOS.

Fewest bytes on the Scheme heap of 64 calls (public API, macOS arm64),
two runs per tree, the same in both:

| Call | main | fix |
|---|---|---|
| `uv-tcp-connect!` | 240 | 240 |
| `uv-getaddrinfo!` | 256 | 256 |
| `uv-getnameinfo!` | 240 | 240 |
| `uv-tcp-bind!` | 112 | 112 |
| `uv-tcp-sockname-address`, `uv-tcp-peer-address` | 176 | 176 |
| `uv-write!` | 144 | 144 |
| `uv-write*!`, one segment | 192 | 192 |
| `make-uv-timer` | 496 | 496 |
| the port and buffer-size queries, the timer verbs, nodelay, keepalive, `uv-now`, `uv-update-time!` | 0 | 0 |
| refused on entry (`uv-tcp-nodelay!`, in a `guard`) | 640 | 672 |
| refused in the step (`make-uv-timer`, in a `guard`) | 960 | 992 |
| control: a `guard` around `(raise 'x)` | 592 | 592 |

A refusal costs the record, 32 B; nothing that is not refused allocates
more.

## Mutations

Each ran in a scratch copy of the fixed tree outside the repo (the
source-reading suites with the copy as their working directory), on
macOS. "Survives" is the suite named passing.

### The builder

| ID | Mutation | Killed by |
|---|---|---|
| B1 | `step-refusal` builds a handle verb's refusal from its loop's owner, read again | test-loop "step-refusal raises each status as the checks outside a step do"; test-owner-refusal's bad-run row (the fifteen verbs); rule 9's `make-uv-wrong-thread` and owner rows |
| B2 | `wrong-thread-refusal` swaps owner and caller | test-loop's three owner rows; test-owner-refusal's owner-check, bad-run and reach rows; 23 rows of test-constructor-owner |
| B3 | `wrong-thread-refusal` takes `actual` from `current-thread-id` | test-loop "step-refusal names the owner and the caller an owner check found, with no handle to pass" only. test-owner-refusal survives: the caller is the current thread in every run |

### The owner checks

| ID | Mutation | Killed by |
|---|---|---|
| C1 | `loop-owner-mismatch` records the caller as the owner | test-owner-refusal's owner-check, bad-run and reach rows; 23 rows of test-constructor-owner |
| C2 | `loop-owner-mismatch` reads the owner again for its record | rule 9's owner row. test-owner-refusal survives: the two reads are one step apart, and only another thread could come between |
| C3 | `owned-handle-ptr` answers a bare `'wrong-thread` | test-owner-refusal's owner-check and bad-run rows; test-handle-steps "a handle verb whose loop changes hands is refused" |
| C4 | `owned-loop-ptr` answers a bare `'wrong-thread` | test-owner-refusal's owner-check, bad-run and reach rows; test-constructors' two handoff rows |
| C5 | `uv-cancel!`'s step answers a bare `'wrong-thread` | test-owner-refusal's bad-run and reach rows; test-request-steps' two cancel handoff rows |
| C6 | `uv-cancel!` builds its refusal from the owner, read again | rule 9's two rows. test-owner-refusal survives (no window) |
| Q1 | `require-loop-thread` builds its refusal from the owner, read again | rule 9's two rows. test-owner-refusal survives (no window) |

### The six former sites, each building its own refusal again

| ID | Site | Killed by |
|---|---|---|
| S1 | `construct-handle` | rule 9's two rows; test-owner-refusal survives |
| S2 | `loop-call` | the same |
| S3 | `uv-spawn!`'s refusal | the same |
| S4 | `uv-getaddrinfo!` | the same |
| S5 | `uv-getnameinfo!` | the same |
| C6 | `uv-cancel!` | the same (above) |

Each survives the sweep because nothing between its step and the read can
trap. With a three-tick loop opened before the read, the sweep kills
each, so it would see one the day a change gives it a window:

| ID | Site, with the three-tick window | Killed by |
|---|---|---|
| W1 | `construct-handle` | test-owner-refusal's bad-run and reach rows |
| W2 | `loop-call` | the same |
| W3 | `uv-spawn!`'s refusal | test-owner-refusal's bad-run row |
| W4 | `uv-getaddrinfo!` | the same |
| W5 | `require-loop-thread` | test-owner-refusal's bad-run and reach rows |
| W6 | `uv-getnameinfo!` | test-owner-refusal's bad-run row |
| W7 | `uv-cancel!` | test-owner-refusal's bad-run and reach rows |

### refused? and symbol?

| ID | Mutation | Killed by |
|---|---|---|
| P1 | `refused?` answers only for a symbol | test-owner-refusal "refused? answers for an owner check's refusal and a symbol, not for a pointer", and its bad-run and reach rows |
| P2 | `uv-timer-repeat`'s step tests its pointer with `symbol?` | rule 9's `symbol?` row. test-owner-refusal survives: this verb's step is never the one to refuse |
| P3 | `uv-process-pid` tests its step's answer with `symbol?` | the same |
| P4 | `uv-tcp-bind!`'s step tests its pointer with `symbol?` | rule 9's `symbol?` row; test-owner-refusal's bad-run and reach rows; test-handle-steps "a handle verb whose loop changes hands is refused" (fuels 11–25: the record reached `uv_tcp_bind`, which raised `invalid foreign-procedure argument` inside the step and left interrupts disabled) |

### The sweep's list (rule 9, added in review)

The hand-back sweep's list of verbs is held to every verb `(libuv)`
exports whose definition reaches an owner check (`require-loop-thread`,
`owned-loop-ptr`, `owned-handle-ptr` or `loop-owner-mismatch`, through
any chain of definitions in `src/`). Run against the fix, the two sets
are the same 39 verbs.

| ID | Mutation | Row's answer |
|---|---|---|
| L1 | the sweep drops `uv-process-pid` | `(unswept (uv-process-pid) not-owner-checked ())` |
| L2 | the sweep lists `uv-now`, which checks no owner | `(unswept () not-owner-checked (uv-now))` |
| L3 | `uv-stop!` checks the owner (`owned-loop-ptr`), unlisted | `(unswept (uv-stop!) not-owner-checked ())` |
| L4 | the suite defines its list under another name | every owner-checked verb unswept |

### The sweep itself

| ID | Mutation | Result |
|---|---|---|
| T1 | no hand-back: the verb is resumed with the loop still handed off | on main's verbs, test-owner-refusal PASSES (twice). The hand-back is what shows the defect |
| T2 | the handoff hands the loop to this thread | the reach row fails: no verb is refused |
| M0 | none, on main's verbs | the bad-run row fails with the fifteen verbs (twice) |

## What is not covered

- **Another thread's claim between a step and its refusal.** No sweep
  runs one, and the window is a few instructions. With the refusal built
  from what the check found, nothing read after the check reaches the
  condition, which rule 9 holds: `make-uv-wrong-thread` only in
  `wrong-thread-refusal`, the owner's accessor only in
  `loop-owner-mismatch`.
- **A second read inside `loop-owner-mismatch`** (C2) is equivalent under
  engines; rule 9's count of one read there holds it.
- **The caller field** (B3): every run's caller is the current thread, so
  only test-loop's row, which hands `step-refusal` another caller, holds
  the builder to the record's.
