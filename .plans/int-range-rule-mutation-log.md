# Rule 14 (no caller's number reaches a C integer unchecked): mutation log

Each mutant was applied to a copy of the worktree outside the repository
(`scratchpad/m14`), run under the copy's own `scripts/guix-env` with
`CHEZ_LIBUV_SHIM` pointed at the copy's shim, and reverted. The final unmutated
copy passed test-source-rules (84), test-c-types (7) and test-native (335).
The word row's faults are named as the final rule names them
(`not-checked-before-the-call`; the first build said `not-checked`).

## Against the source

| # | Mutation | Failed, by name |
|---|---|---|
| R1 | `uv-kill!` without its `c-int?` check | rule 14 word row `((uv-kill 1 uv-kill!)) not-checked-before-the-call pid c-int?`; test-process's pid-range rows (Chez's malformed condition back) |
| R2 | `uv-listen!`'s backlog check by `integer?` | word row `((uv-listen-native 2 uv-listen!)) not-checked-before-the-call backlog c-int?` |
| R3 | `uv-write*!` without its count check | word row `((start-write! 5 uv-write*!)) not-checked-before-the-call n c-unsigned-int?`; no suite can reach 2^32 segments, so only the rule holds it |
| R4 | `uv-write*!` checks `(length specs)`, passes `n` | the same word row |
| R5 | a new `kill-group!` calling `uv-kill` directly | coverage `(unworded ((uv-kill 1 kill-group!) (uv-kill 2 kill-group!)) …)` |
| R6 | a new foreign call `raw-foo (int)` and its applier | coverage `(unworded ((raw-foo 1 foo!)) …)` |
| R12 | `valid-port?` written without `c-int?` | word row, `not-checked-before-the-call port c-int?` for both address families |
| R14a | `2147483648` written out in tcp.sls | bound row `(("src/libuv/tcp.sls" 2147483648))` |
| R14b | `(expt 2 64)` written out in timer.sls | bound row `(("src/libuv/timer.sls" (expt 2 64)))` |
| R15 | a second `c-int?` in lists.sls (which imports no c-types) | predicate row `((c-int? "…/c-types.sls" "…/lists.sls"))` |
| R16 | a foreign call taking `boolean` | boolean row `(raw-flag)` |
| R17 | one definition holding two foreign calls | one-call row `(raw-pair)` |
| R18 | the stdio count written with `c-int-set!` again | writer row `(("src/libuv/process.sls" fill-scalars! 1))` |
| R19 | a foreign call taking `stdbool` | boolean row `(raw-flag)` |
| R20 | `alloc-block` without `c-size?` | word row `((raw-alloc 1 alloc-block)) not-checked-before-the-call n c-size?` |
| C1 | `c-int?`'s max computed as the unsigned range | test-c-types' c-int? row `(in in in in)`; test-process's pid and inherit-fd rows |
| C2 | `within?` tests `exact?` before `integer?` | test-c-types' non-integer row (actual `#f`: `exact?` raised on `"1"`, which a verdict list cannot be) |
| C3 | `c-size?` sized as an int | the c-size? row `(out in out out)` and the fixnum row `(in out)` |
| C4 | `try-c-u32-set!` without its range check | its row: 4294967296 raised inside the step, and -1 was written as 4294967295 |
| C5 | `c-int-set!` without its range check | its row `(no-raise wrong-condition)`: 2147483648 written, -2147483649 refused by Chez |
| C6 | `try-c-int-set!` without its address bound | its row: `foreign-set!` raised at 2^64 |

## Against the table

| # | Mutation | Failed, by name |
|---|---|---|
| R7 | a worded place that is none, `(uv-kill 1 uv-os-getpid)` | coverage `(not-a-place ((uv-kill 1 uv-os-getpid)))`, and word row `no-call-site` |
| R8 | `uv-kill!`'s entry names `c-u64?` | word row `predicate-not-for int c-u64?` |
| R9 | `uv-listen-native` forwards parameter 1 | word row `does-not-pass-parameter 1 (backlog)`, and coverage |
| R10 | `uv-listen-native` worded `constant` | word row `passes-its-parameter (backlog)`, and coverage |
| R13a | the type map without `unsigned-int` | word row, `predicate-not-for unsigned-int` for keepalive and the write count |
| R13b | the type map without `unsigned-64` | word row, `predicate-not-for unsigned-64` for the three timer places |

## Against the scan's plumbing

| # | Mutation | Failed, by name |
|---|---|---|
| C10 | `int` listed among the non-integer scalars | live row, coverage, word row |
| P2 | `appliers` finds none | coverage, every place `not-a-place` |
| P3 | `binding-call?` ignores `handle-call!` | word row `no-call-site` for the nodelay and both keepalive places |
| P4 | `check-position` finds nothing | word row, every `caller` place `not-checked-before-the-call` |
| P5 | the bound scan finds nothing | its live row `()` |

## After the second review (the built rule)

An Opus review of the built rule found holes; each became a mutant.

| # | Mutation | Failed, by name |
|---|---|---|
| N2 | `(apply uv-kill (list pid 0))`, worded `constant` | word row `no-call-site`: every word but `via` needs a call |
| N3 | a case-lambda forwarding parameter 1 in one arm and 2 in the other | word row `does-not-pass-parameter 1 ((other pid))`: checked per arm |
| N4 | `uv-kill!` checks with `(define (pid-ish? x) (or (c-int? x) (integer? x)))` | word row: a family member must be `(P x)` or `(and (P x) …)` |
| N5 | an applier inside a top-level `begin` | coverage `unworded`: `src-definitions` splices begins |
| N6 | a foreign binding made by `define-values` | the held-call row `("uv_dv")` |
| N7 | `uv-kill!` checks after its call | word row `not-checked-before-the-call` |
| N10 | `(- (expt 2 (- (* 8 (foreign-sizeof 'int)) 1)) 1)` in native.sls | bound row: an exponent computed from `foreign-sizeof` |
| N11 | `via` naming a procedure the applier does not hand the binding to | word row `not-handed-to other-start!` |
| N12 | a place with no call worded `constant` | word row `no-call-site` |
| N13 | `uv-errno-condition` without its `c-int?` check | word row; test-native's unknown-error row, where 2^31 reached `uv_strerror_r` as -2147483648 and -2^40 raised Chez's malformed condition |
| N14 | `uv-write!`'s start checked by `integer?`/`exact?` | word row `((copy-in-unchecked! 3 uv-write!)) not-checked-before-the-call start c-size?` |
| C7 | `c-u32-set!`'s range check by `integer?` | its row `(wrong-condition no-raise)` |
| C8 | `try-c-u32-set!` without its address bound | its address row: `foreign-set!` raised at 2^64 |
| C9 | `zero-out!`'s length check without `c-size?` | word row, and test-native's size_t row (Chez's malformed condition for 2^64) |

Every mutant failed only the rows named, and passed again once reverted.

## Uncovered

Three of the second review's holes stay green, and the rule's header names
each as what the scan cannot see:

- N1: `(let ((p pgid)) (uv-kill p 0))` worded `constant`: an alias of a
  parameter is not a parameter by spelling.
- N8: `(unless (or (c-int? backlog) (integer? backlog)) …)`: the check
  precedes the call but does not guard it.
- N9: `(let ((pid (+ pid pid))) (uv-kill pid signum))` after the check: a
  variable rebound between the check and the call. `uv-write*!` relies on
  that matching, rebinding `n` to its checked value.

And as before:

- Whether a `constant`, `libuv` or `size` word is true, beyond a constant
  or libuv place passing no parameter of its own: review holds it.
- A binding passed as a value to a procedure that calls it (`r-call`,
  `start-signal!`, `construct-handle`, `buffer-size-step`): its places are
  the definitions that pass it, and their words cannot be checked against a
  call.
- `fill-scalars!`'s stdio-count refusal needs 2^31 stdio entries; the
  writer row holds that it answers rather than raises.
