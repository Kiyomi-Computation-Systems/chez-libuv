# #118: a raise out of call-with-uv-loop's body under guards: mutation log

Branch `fix/guard-reraise-118`, on main a865828, 2026-10-09. Guix container
(ADR-0020), x86_64, Chez 10.4.1, libuv 1.52.1.

## What was wrong

R6RS `guard` unwinds to itself before it tests its clauses. When none
matches, it re-raises in the dynamic environment of the original raise, so
it re-enters the body's `dynamic-wind`. `call-with-uv-loop`'s entry thunk
refuses every return into a body it has left (#45), and its refusal raised
`&uv-handle-closed`. That replaced the body's own condition:
- a guard whose clauses did not match handed its caller `&uv-handle-closed`;
- a guard with a `uv-error?` clause took a user's error for the binding's.

## Two measurements first

A probe on plain `dynamic-wind` (build/, not kept):
1. **Chez's `guard` re-enters.** With an unmatched inner guard, the trace
   was: exit thunk, entry thunk again, the handler outside, exit thunk. The
   condition reached the outer guard intact.
2. **During that re-entry, the guard's own handler is current.** A raise
   from the entry thunk was seen by the inner guard's clauses a second time.
   When they did not match, it went on outward with no further re-entry,
   since the entry thunk's raise point is outside the extent.

## The decision

The issue listed three directions without choosing one.

- **Catch the body's raise, tear down, re-raise from outside (rejected).**
  Outer handlers would run outside the body's dynamic environment, losing
  its `parameterize` and running its `dynamic-wind` thunks around every
  raise. A `raise-continuable` they return from could no longer resume the
  body: a Chez `warning` in a body would abort it. It would also escape
  across any C frames a raise sits under (AGENTS.md, the stranded-frame
  trap).
- **Tell a guard's re-raise from a real resumption in the entry thunk (not
  possible).** Entry thunks run outermost first, so `call-with-uv-loop`'s
  runs before any marker the target could carry.
- **Chosen: the refusal raises the body's raise again, once.** A handler
  installed around the body records the raise it is handing on, and hands
  it on in place with `raise-continuable`. The exit thunk keeps the record.
  On the first re-entry, the entry thunk raises that raise if there was
  one, and clears it. Every other re-entry raises `&uv-handle-closed`. It
  is still a refusal: nothing ever resumes a body that has been left. The
  guards outside get the body's own condition.

The costs, documented in docs/api.md and each held by a row:
- A guard whose clauses do not match tests them a second time, and a
  handler between it and the body sees the condition twice.
- A handler that retries the body by re-entering it gets the raise once
  more, then `&uv-handle-closed`.
- A handler that returns from the body's `raise` is called once more, with
  the `&non-continuable`. R6RS raises that from the handler returned to,
  which is now `call-with-uv-loop`'s. This one reaches code that never hit
  #118. Any fix that passes the body's condition on has to see it, so it
  has to interpose a handler, and so has this cost; the issue's first
  direction interposes too.

The record is a one-element list, so a body that raises `#f` is told from
one that raised nothing. It goes back to `#f` when the handler returns, and
when the body returns: a raise in the body can only interrupt another whose
handling was given up by a jump back into the body, and that record is
stale.

## The rows

`tests/test-loop-guard.sps`, a new suite (18 rows after the review). Every condition row
compares with `eq?` against one condition object, so only the body's own
raise passes. `&uv-handle-closed`, another `&error`, or SRFI-64's `#f` cannot.

| Row | Expects |
|---|---|
| a catch-all guard | the body's own |
| a guard that does not match, inside a catch-all | the body's own |
| a `uv-error?` guard, inside a catch-all | the body's own, not handled as the binding's |
| `(raise #f)` through a guard that does not match | `(got #f)` |
| a guard that does not match tests its clauses | `(the-bodys-own 2)` |
| `raise-continuable` the handler returns from | `(42 fired)`: resumed, its loop still runs a timer |
| a guard that does not match a `raise-continuable`, a returning handler outside it | `not-resumed` |
| a raise the body was resumed from, then an exit by continuation and a re-entry | `(handle-closed loop)` |
| two raises, the first resumed | the second, the body's own |
| two later re-entries after a matching guard | `(handled 2 entered 1 past 1 then handle-closed)`: the first raises the raise, the second is refused as closed, and the body's code after the capture runs once |
| a handler that retries the body by re-entering it, outside an unmatched guard | `((outer-got handle-closed) retries 1 body-runs 1)` |
| a handler jumps back into the body, the body returns, then a re-entry | `(handle-closed)` |
| a handler between an unmatched guard and the body | sees `(the-bodys-own the-bodys-own)` |
| a handler that returns from the body's `raise` | sees `(the-bodys-own non-continuable)` |
| a handler answers the body's `raise-continuable` with `(values 1 2)` | the body gets `(1 2)` |
| the body returns `(values 1 2)` | the caller gets `(1 2)` |
| an engine suspended by `engine-block` in the handler outside | `(the-bodys-own 1 2)`: the handler is called again on the resume |
| every row's loop | torn down |

The engine row's run, `blocked-raise-run`, is listed in test-sweep's engine
census, bounded at 10 resumes.

## Evidence

Before the review the suite had 12 rows. On main, 7 failed by name, each
with `&uv-handle-closed` where the body's own condition belongs.

**After the review**, on main's `loop.sls`, 10 of the 18 rows fail by name.
The 8 that pass hold what the fix must keep, each with a mutant below.

**Mutants of `src/libuv/loop.sls`**, each first on `CHEZSCHEMELIBDIRS`;
correct build 18 of 18:

| Mutant | Fails by name |
|---|---|
| K2: the record not in a list | `#f`: `(got #<condition &uv-handle-closed>)` |
| K3: the record not reset when the handler returns | the resumed raise: `&non-continuable`, after the stale record was raised again and the handler returned from it |
| K5: the raise handed on with `raise`, not `raise-continuable` | 5 rows: every row that resumes a raise, and the `&non-continuable` count `(the-bodys-own)` |
| K6: a re-entry allowed when the body was left raising | 6 rows: the clause count, `resumed`, `(handled 3 entered 1 past 3 attempts 3)`, the retry `(retried …)`, the handler between `(the-bodys-own)`, the engine `(the-bodys-own 1 1)` |
| K7: the handler swallows the raise | 15 rows |
| K8: no teardown when left raising | every row's loop: `11` left live |
| K9: the refusal not one-shot | the two re-entries `(handled 3 …)`, the retry `((outer-got the-bodys-own) retries 5 …)` |
| K10: the record not cleared when the body returns | the jump-back row: `the-bodys-own` |
| KMV-handler: the handler's answers taken as one value | the handler's several answers: `&non-continuable` |
| KMV-body: the body's values taken as one value | the body's several values: "returned 2 values to single value return context" |

The two-raise row fails only under main, K5 and K7, which other rows catch
too. No mutant breaks it alone: the reset that keeps a stale record from
leaking into the second raise is K3's, held by the resumed-raise row.

## The window an engine can still fall in

A probe swept an engine's first slice over a body that raises under an
unmatched guard inside a catch-all, then resumed it with a fixed budget:

| First slice (ticks) | Resumed, the catch-all got |
|---|---|
| 1–16 | the body's own: expired before `call-with-uv-loop` was entered |
| 17–27 | `&uv-handle-closed`: expired inside the body before the raise was recorded |
| 28–96 | the body's own |
| 97 | finished in the first slice |

No run resumed the body, none got any other condition, and every loop was
torn down (0 live before and after). Re-measured after the review's
changes: the same bands. Ticks 17–27 include the loop's
construction and the call into the body, where `&uv-handle-closed` is right,
and the few ticks from the raise to the record. Those last cannot be closed:
the call into the handler is itself a tick, before any of its code runs.
The ticks between the handler's return and its reset are the same kind:
there the refusal raises the finished raise.

## Not covered

- **The engine window above.** Both outcomes are refusals; only which
  condition differs. No row pins it.
- **An outer handler that jumps back into the body, then an exit before
  the body returns.** The record of the raise the handler gave up stays
  set until the body returns or another raise is handled. An exit by
  continuation or engine before that, and a re-entry, raise the old raise
  once.

## The review

An adversarial review on Opus (read-only) found no hole in the #45
guarantee: nothing resumed a body that had been left, at any engine
expiry, through the callback, teardown or nested paths. It found seven
problems with the first version, each reproduced before it was acted on:

1. **A restart handler looped for good.** A handler outside an unmatched
   guard that retried the body by re-entering it got the raise back on every
   retry: 20 retries in a probe capped at 20, where main gave
   `&uv-handle-closed` at once. Fixed: the refusal raises the raise once.
2. **docs/api.md said every other re-entry is refused with
   `&uv-handle-closed`.** After a handler jumped back into the body and the
   body returned, a re-entry got the old raise. Fixed: the body's return
   clears the record, and the docs state the one-shot rule.
3. **The code comment said handlers outside run as if the handler were not
   there.** A handler that returns from the body's `raise` saw
   `(X non-continuable)` against main's `(X)`. Not fixable while passing the
   condition on (see "The decision"). Now in the comment, the docs and a row.
4. **The docs left out that a handler between an unmatched guard and the
   body sees the condition twice.** Probe: `(X X)`. Documented, with a row.
5. **The later-re-entry row could not fail for "the body never runs
   again".** K6 passed it. It now counts the code after the capture.
6. **The engine row passed under K6.** It now counts the handler's calls.
7. **No row held several values through the handler.** It now has one, and
   one for the body's values.

## Gates

In the container: `make test` (35 suites, all passed), `make check-purity`,
and `make HAVE_PKG=no test-memory MEMORY_TESTS="tests/test-loop-guard.sps
tests/test-loop.sps"` (0 bytes definitely lost; nothing suppressed in the
new suite). After the review: `make test` again, and the Valgrind run with
test-loop-claim added: 0 bytes definitely lost in all three; nothing
suppressed in the new suite, 6 blocks in test-loop and 22 in
test-loop-claim, both on `MEMORY_ESCAPE_SUITES`.
