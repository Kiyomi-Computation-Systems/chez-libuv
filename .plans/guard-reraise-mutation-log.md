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
- **Chosen: the refusal raises the body's raise again.** A handler
  installed around the body records the raise it is handing on, and hands
  it on in place with `raise-continuable`. The exit thunk keeps the record.
  The entry thunk, on a re-entry, raises that raise if there was one, else
  `&uv-handle-closed`. It is still a refusal: nothing ever resumes a body
  that has been left. The guards outside get the body's own condition.

The costs, documented in docs/api.md:
- A guard whose clauses do not match tests them a second time.
- Any later re-entry into a body left by a raise also raises that raise. A
  continuation the body captured and someone calls after a matching guard
  has handled the raise gets it again, not `&uv-handle-closed`.

The record is a one-element list, so a body that raises `#f` is told from
one that raised nothing. It goes back to `#f` when the handler returns, not
to an earlier record: a raise in the body can only interrupt another whose
handling was given up by a jump back into the body, and that record is
stale.

## The rows

`tests/test-loop-guard.sps`, a new suite (12 rows). Every condition row
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
| a later re-entry after a matching guard | `(handled 2 entered 1)`: the guard handles it twice, the body runs once |
| an engine suspended by `engine-block` in the handler outside | `(the-bodys-own 1)` |
| every row's loop | torn down |

The engine row's run, `blocked-raise-run`, is listed in test-sweep's engine
census, bounded at 10 resumes.

## Evidence

**main's `loop.sls`**: 7 rows fail by name, each with `&uv-handle-closed`
where the body's own condition belongs: the unmatched guard, `uv-error?`,
`#f`, the clause count, two raises, the later re-entry, the engine. The
other 5 pass on main; they hold what the fix must keep.

**Mutants of `src/libuv/loop.sls`**, each first on `CHEZSCHEMELIBDIRS`;
correct build 12 of 12:

| Mutant | Fails by name |
|---|---|
| K2: the record not in a list | `#f`: `(got #<condition &uv-handle-closed>)` |
| K3: the record not reset when the handler returns | the resumed raise: `&non-continuable`, after the stale record was raised again and the handler returned from it |
| K5: the raise handed on with `raise`, not `raise-continuable` | the resumed body, and the two rows that resume a raise |
| K6: a re-entry allowed when the body was left raising | the clause count `(the-bodys-own 1)`, and `resumed` |
| K7: the handler swallows the raise | 10 rows, the catch-all among them: `&non-continuable` |
| K8: no teardown when left raising | every row's loop: `9` left live |

The two-raise row fails only under main and K7, which other rows catch too.
No mutant breaks it alone: the reset that keeps a stale record from leaking
into the second raise is K3's, held by the resumed-raise row.

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
torn down (0 live before and after). Ticks 17–27 include the loop's
construction and the call into the body, where `&uv-handle-closed` is right,
and the few ticks from the raise to the record. Those last cannot be closed:
the call into the handler is itself a tick, before any of its code runs.
The ticks between the handler's return and its reset are the same kind:
there the refusal raises the finished raise.

## Not covered

- **The engine window above.** Both outcomes are refusals; only which
  condition differs. No row pins it.
- **An outer handler that jumps back into the body.** If a handler outside
  abandons a raise by calling a continuation captured inside the body, the
  record stays set until another of the body's raises is handled and
  returned from. An exit and a re-entry before that raise the old raise.

## Gates

In the container: `make test` (35 suites, all passed), `make check-purity`,
and `make HAVE_PKG=no test-memory MEMORY_TESTS="tests/test-loop-guard.sps
tests/test-loop.sps"` (0 bytes definitely lost; nothing suppressed in the
new suite).
