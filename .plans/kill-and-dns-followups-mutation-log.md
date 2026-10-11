# uv-kill! pid range, first-call load, and the private chain walker: mutation log

Each mutant was applied to a copy of the tree outside the repository
(`scratchpad/mkill`), run under that copy's own `scripts/guix-env` with
`CHEZ_LIBUV_SHIM` pointed at the copy's shim and `CHEZ_LIBUV_TEST_CHEZ` set,
and reverted. The unmutated copy passed test-process (169) and test-dns (162).

## Red before the fix

Against the tree before the fix, with the new rows in place, test-process
failed exactly these four, each for its own reason:

- "uv-kill! refuses a pid above a C int's range by name": actual
  `((raised "Exception in $oops: invalid who argument uv-kill …") in-range in-range)`.
  2^40 raised Chez's malformed condition, and 4294967295 and 2147483648
  both reached kill(2), wrapped.
- "uv-kill! refuses a pid below a C int's range by name": both raised the
  malformed condition.
- "uv-kill! with signal 0 as the first call names kill(2)'s errno" and
  "… with 'sigterm …": actual `(invalid-argument constants-not-initialized)`.

The seed row ("the first-call children had no constants until uv-kill!")
passed: importing `(libuv)` reads no constants.

Chez's `int` foreign argument takes -2^31 to 2^32-1 and keeps the low 32
bits: `abs` called through `(foreign-procedure "abs" (int) int)` answers 1
for 4294967295 and -2147483648 for 2147483648. So before the fix
`(uv-kill! 4294967295 sig)` was `kill(-1, sig)`.

## Mutants

| # | Mutation (src) | Suite | Failed, by name |
|---|---|---|---|
| M1 | drop `(ensure-native-loaded!)` from `uv-kill!` | test-process | both first-call rows |
| M2 | load after `signal-symbol->int` | test-process | the `'sigterm` first-call row only |
| M3 | upper bound 2147483648 | test-process | "refuses a pid above a C int's range" |
| M4 | lower bound -2147483649 | test-process | "refuses a pid below a C int's range" |
| M5 | upper bound 2147483646 | test-process | "hands either end of a C int's range to kill(2)" |
| M6 | lower bound -2147483647 | test-process | "hands either end of a C int's range to kill(2)" |
| M7 | upper bound 4294967295 (the unsigned range) | test-process | "refuses a pid above a C int's range" |
| M8 | `(libuv dns)` exports `addrinfo-chain->list` again | test-dns | "(libuv dns) exports its verbs but not the raw chain walker" |

Each failed only the row named, and passed again once reverted.

## After the code review

The review asked for one C int predicate. `c-int?` now holds the bounds,
and `c-int-fd?` is `c-int?` at 0 or above, so the bounds mutants above were
rerun against `c-int?` itself. The unmutated copy passed test-process (171,
with the two fd rows below).

| # | Mutation (src) | Failed, by name |
|---|---|---|
| M3 | `c-int?` upper bound 2147483648 | "refuses a pid above a C int's range" (actual `(pid-out-of-range pid-out-of-range in-range)`), and the fd rows "an inherit-fd value too wide for the C int container field" and "validation created no process handle", since `c-int-fd?` shares the bound |
| M4 | lower bound -2147483649 | "refuses a pid below a C int's range" |
| M5 | upper bound 2147483646 | "hands either end of a C int's range to kill(2)" (actual `(pid-out-of-range in-range)`) |
| M6 | lower bound -2147483647 | "hands either end of a C int's range to kill(2)" (actual `(in-range pid-out-of-range)`) |
| M7 | upper bound 4294967295 | "refuses a pid above a C int's range", and the same two fd rows as M3 |
| M9 | `uv-kill!` skips `c-int?` | both refusal rows, with Chez's malformed condition as the actual |
| M10 | `c-int-fd?` floor -1 | the new "an inherit-fd value below 0" (actual `#f`: libuv's errno passed through), and a cross-thread stdio sweep row |
| M12 | `c-int-fd?` floor 1 | the new "an inherit-fd value of 0, stdin, passes the fd check" (actual `(refused stdio-fd-not-an-fd)`) |

M10 and M12 were added because the refactor touched `c-int-fd?`, and no
row held its floor: before the two rows, M12 survived, and M10 failed only
the sweep row.

The review also found that the first-call child wrote a raise with no
message as `#<condition …>`, which `read` cannot parse. With `uv-kill!`
raising `&uv-handle-closed` for the child's pid only (M11), the rows showed
`(no-entry kill (unreadable …))` before the child wrote `describe`'s text,
and `(raised "Exception occurred with condition components: …
&uv-handle-closed: process")` after.

## Uncovered

- test-tcp's "a handle with no socket yet refuses with EBADF" holds libuv's
  answer, which the docs and `uv-tcp-peer-address`'s comment state. The
  binding makes no decision there to mutate: it hands libuv's status on.
- The first-call seed row holds a property of the facade's import (it reads
  no constants), not a decision in the code under test.
