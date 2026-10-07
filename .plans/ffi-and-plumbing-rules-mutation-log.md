# FFI source rules, and the address verbs out of suite plumbing: mutation log

Issue #64, items 2 and 5. Branch `test/ffi-rules-and-dns-plumbing`, from
`main` at a473313. Chez 10.4.1 on macOS arm64.

The first version of this branch (a7095f0) went through a max-effort
/code-review: ten finder angles, a verifier for each of 18 candidates, and a
gap sweep. All 18 were confirmed, none refuted. This log records the design
as reworked after that review; "The review" below lists what it found.

Nearly all of it is test-only. The one change to `src/` beyond comments:
`chez_uv_constant` now receives its name as C-string bytes (item 2 below).
No shim change, and no release note: the path is reachable only through
`(libuv private constants)`.

## Item 2: the FFI source rules

`tests/test-source-rules.sps` reads every foreign call in `src/` as data.

- **Rule 3.** No foreign call takes a string type. Chez encodes such an
  argument during the call, so a string changed after it was checked
  reaches C changed, and a NUL cuts it short (#51, #61).
- **Rule 4.** No `__collect_safe` foreign call takes an argument in Scheme
  memory. Another thread's collection can move it while C reads it (#35).
- **Rule 5.** Every foreign call is a form rules 3 and 4 read. So `src/`
  has no function ftype and no ftype alias of a pointer type. No macro but
  `shim-procedure` wraps `foreign-procedure`, and nothing is imported from
  `(chezscheme)` renamed or prefixed. The type families are complete
  against what Chez's expander accepts.

### What Chez does with each argument type

Enumerating the oblist (9,627 symbols) through
`(expand '(lambda () (foreign-procedure conv "strlen" (T) void)))` with one
environment takes 22 ms. 57 symbols are accepted parameter types:

| family | types | plain call | `__collect_safe` |
|---|---|---|---|
| string (9) | `string` `wstring` `utf-8` `utf-16` `utf-16le` `utf-16be` `utf-32` `utf-32le` `utf-32be` | accepted | refused: "string argument not allowed with __collect_safe procedure" |
| address (7) | `u8*` `u16*` `u32*` `scheme-object` `ptr` `ftype-scheme-object-pointer` `ftype-pointer` | accepted | accepted |
| scalar (41) | the integer, float, `char`, `wchar`, `boolean`, `stdbool`, `fixnum`, `iptr`, `uptr`, `void*` types | accepted | accepted |

- `ptr` is `scheme-object`: the fixnum 5 crosses as 40, and a bytevector as
  its tagged address, through either.
- `ftype-pointer` was missing from the first version's address family. A
  `(make-ftype-scheme-object-pointer bv 0)` value passed through an
  `ftype-pointer` parameter hands C the bytevector's data address, the same
  address `u8*` gives. The review measured the hazard directly. A
  `__collect_safe` C function held that address while another thread ran
  `(collect 0 1)`. The bytevector moved, and C's write was lost, in 4 of 4
  runs.
- Of the 41 scalars, only `boolean` and `stdbool` take a heap object, and
  they pass 1, not an address.
- A `(* ftype)` or `(& ftype)` parameter refuses a scheme-object pointer at
  the call ("invalid foreign-procedure argument").
- A `define-ftype` alias of `ftype-pointer` or `ftype-scheme-object-pointer`
  is accepted as a parameter type and passes the same address. That is why
  rule 5 forbids such aliases.
- A `function` ftype called through `ftype-ref` is a foreign call too. It
  accepts `__collect_safe` with `u8*`. A rewrite of `raw-copy-out` that way
  passed every `make test` suite and failed only test-threading-stress
  (#35's hazard), which `make test` and CI do not run.

The completeness row checks that the three lists are exactly the 57 types:
a type a later Chez adds fails it until classified.

### The census on main

On a473313 the scan finds 110 foreign calls, all in `native.sls` (one is
`shim-procedure`'s template). Sixty are `foreign-procedure` and fifty
`shim-procedure`. There is one string parameter (`chez_uv_constant`), eight
`u8*` bindings and one `__collect_safe` call (`uv_run`).

### `chez_uv_constant`

The first version allowlisted `chez_uv_constant`'s string parameter, on a
comment that it "receives only the binding's own constant names". No check
held that. `constant-ref` forwards any symbol's name, and C reads it only up
to its first NUL:

- `(constant-ref (string->symbol "UV_EOF\x0;junk"))` answered -4095,
  UV_EOF's value;
- `'SIGKILL\x0;anything` answered 9.

The path needs `(libuv private constants)`, and every name `src/` passes is
a literal. Now `raw-constant` takes `u8*`, and `lookup-constant` hands it
the name's C-string bytes, answering `#f` for a name holding a NUL.
`constant-ref` then raises `&uv-constant-unavailable` naming the symbol, as
for any unknown name. Rule 3 needs no allowlist.

`tests/test-native.sps`'s new row fails by name on the old code, with
actual `(answered -4095)`.

### Mutations

Each ran in a fresh copy of `src/` and `tests/` outside the repo; every edit
had to match exactly once.

| id | mutation | fails by name |
|---|---|---|
| S0 | none (control) | nothing: test-source-rules 24, test-native 307 pass |
| S1 | `uv_ip4_addr` takes `string` | "no foreign call in src/ takes a string type" |
| S1b | `uv_ip6_addr` takes `utf-8` | the same |
| S1c | `chez_uv_constant` takes `string` again | the same |
| S2 | `uv_strerror_r` marked `__collect_safe` | "no __collect_safe foreign call in src/ takes an argument in Scheme memory" |
| S2b | `uv_getaddrinfo` marked `__collect_safe` | the same |
| S2c | `uv_run` takes `scheme-object` | the same |
| S2d | `uv_run` takes `ftype-pointer` (passed the first version) | the same |
| S4 | the scan ignores `shim-procedure` forms | the liveness row (60 calls, not 110), the string seeded row |
| S5 | the scan looks for `collect_safe` | the liveness row, the collect-safe seeded row |
| S6 | the scan reads the result type as a parameter | the string seeded row |
| S7 | the scan counts `foreign-callable` forms as calls | both seeded rows |
| S8 | `utf-16le` dropped from the string family | the string seeded row, the completeness row |
| S9 | `ptr` dropped from the address family | the collect-safe seeded row, the completeness row |
| S9b | `ftype-pointer` dropped from the address family | the same two |
| S10 | `utf-8` misspelt `utf8` | the string seeded row, "Chez encodes each string type…", the completeness row |
| S11 | `ftype-scheme-object-pointer` misspelt | the collect-safe seeded row, "Chez accepts each address type…", the completeness row |
| S12 | the verdict matches a shorter refusal message | "Chez encodes each string type…" |
| S13 | the verdict drops the convention | the same |
| S14 | the verdict's environment lacks `foreign-procedure` | the verdict's control row, both Chez rows, the completeness row |
| S15 | `__collect_safe` seen only as the first convention | the collect-safe seeded row (its `(__varargs_after 1) __collect_safe` call) |
| S16 | `uv_run` loses `__collect_safe` | the liveness row |
| S17 | the scan reads only the first parameter | both seeded rows |
| S18 | `uptr` dropped from the scalars | the completeness row (unlisted) |
| S19 | `u64*`, not a type, added to the scalars | the completeness row (not accepted) |
| S20 | the enumeration reads an empty oblist | the completeness row |
| S21 | `native.sls` gains a `__collect_safe` function ftype | "no define-ftype in src/ is a function type or an alias of a pointer type" |
| S22 | `native.sls` gains `(define-ftype sop-alias ftype-pointer)` | the same |
| S23 | the ftype scan ignores `function` | the rule-5 ftype seeded row |
| S24 | `native.sls` gains a macro wrapping `foreign-procedure __collect_safe` | "no macro in src/ but shim-procedure wraps foreign-procedure" |
| S25 | `c-string.sls` imports `foreign-procedure` renamed | "no library in src/ imports from (chezscheme) renamed or prefixed" |
| S26 | the macro scan ignores `let-syntax` | the rule-5 macro seeded row |
| S27 | the import scan ignores `prefix` | the rule-5 import seeded row |
| S29 | `lookup-constant` passes a NUL-bearing name on | test-native's "a constant name holding a NUL names no constant…" |

33 of 33 caught by name, the controls green.

## Item 5: verbs that end a suite when they raise

### Rule 4

`tests/test-seed-gates.sps`'s rule 4 holds every suite that calls an address
or DNS verb: `uv-getaddrinfo!`, `uv-getnameinfo!`, `uv-cancel!`,
`uv-tcp-bind!`, `uv-tcp-connect!` or `fill-sockaddr!`. A row derives that
list from the files: test-address, test-dns, test-facade, test-flow,
test-native and test-tcp. In each, a verb, or a procedure of the suite's
own that a raise from one can leave, is called only where a raise fails a
row:

- in a row's tested expression;
- in a procedure the suite defines, whose calls are held in turn;
- in the body of a guard with an `else` or `#t` clause that raises nothing
  again.

The rule reads what runs at once: the top-level forms, the bodies
`with-loop` runs, every lambda that is not a callback, a quasiquote's
unquoted parts, and a verb passed as a value. It also reads each callback's
body, wherever the callback was registered, because uv-run re-raises a raise
in a callback from the wait that runs it.

It does not follow procedures a suite imports. `tests/uv-testing.sls`'s
`bind-loopback!` and `connect-loopback!` call `uv-tcp-bind!` and
`uv-tcp-connect!` (below).

On a473313 it finds:

- test-dns, 24: the 19 direct calls, `(h-submit! 1)`, the synthetic
  sockaddr, the same-turn `uv-cancel!` and both retry loops. Plus `h-submit!`'s
  resubmission from its own on-complete, which the first version missed
  (the review found it four ways).
- test-tcp, 2: the binds at lines 178 and 216.
- test-facade, 8; test-flow, 2. The first version's hand-picked suite list
  left these two suites out.

Each start now runs where a raise fails a row that carries the condition as
its actual value. Suites that did not print a failing row's actual value
gained the hook that does. Values later plumbing reads start as a
placeholder, and the forms that read them are gated:

- the port read after a bind, and test-flow's buffer sizes;
- the synthetic node's address and its `free!`;
- the drain on a loop the EBUSY row closed;
- test-facade's expected value that read a port, now read in its row.

A raising retry attempt ends its loop and reports itself as raised in each
row and display line that reads it. What it started is cleaned up first:
the double-cancel attempt's lookups are drained, and the teardown attempt
tears down its own loop.

### Forced failures, main's suites against these

Each verb was made to raise in a scratch copy of `src/`. Main's `tests/`
(a473313) and this branch's ran against the same copy. "255" is an abort
with no summary; "1: a / b" is a summary with a passes and b failures.

| id | planted failure | dns main → branch | facade main → branch | tcp main → branch | flow main → branch |
|---|---|---|---|---|---|
| F1 | MA8: `c-string-bytes` drops the terminator | 255 → 1: 52 / 97 | 255 → 1: 53 / 23 | 255 → 255 | 255 → 255 |
| F2 | `fill-sockaddr!` refuses every address | 255 → 1: 115 / 34 | 255 → 1: 57 / 19 | 255 → 255 | 255 → 255 |
| F3 | `uv-getaddrinfo!` raises on entry | 255 → 1: 70 / 79 | 255 → 1: 69 / 7 | | |
| F4 | `uv-getnameinfo!` raises on entry | 255 → 1: 112 / 37 | 255 → 1: 73 / 3 | | |
| F5 | `uv-cancel!` raises on entry | 255 → 1: 139 / 10 | 255 → 1: 75 / 1 | | |
| F6 | IPv6 parsing refused | 255 → 1: 145 / 4 | 0 → 0 | 255 → 1: 236 / 2 | 0 → 0 |
| F7 | `uv-getaddrinfo!` refuses a submit made while its loop runs | 255 → 1: 148 / 1 | 0 → 0 | | |

- Under F1 and F2, test-tcp and test-flow fail their converted bind rows by
  name, then end at their first loopback fixture (below).
- F5's 10 failures in test-dns all name `uv-cancel!` or the double-cancel
  rows. Before the cleanup, two more failed on correct code:
  - the getnameinfo boundary row, with `(1 7)`;
  - the teardown balance row, with `(balance 4 1 7)`.
- F7 is the callback case. The chain row fails carrying the condition.
- Each failing start row carries its condition, e.g.
  `(raised "… &uv-invalid-argument who: uv-getaddrinfo! reason: planted")`.

### Mutations (rule 4)

| id | mutation | fails by name |
|---|---|---|
| T0 | none (control) | nothing: 72 pass |
| T1 | rows not treated as containing their tested expression | the seeded rows, test-dns's, test-tcp's and test-flow's rows |
| T2 | any guard treated as catching everything | "rule 4 flags a verb…" |
| T3 | a catch-all guard's body walked | the seeded rows, every suite's row but test-native's |
| T4 | lambdas skipped wholesale, as in the first version | "rule 4 flags a verb…", the procedure row |
| T5 | quoted data walked | "rule 4 flags a verb…", test-address's, test-dns's and test-tcp's rows |
| T6 | procedures found in one pass, not to a fixpoint | the procedure row |
| T7 | a procedure counted by any call, guarded or not | the procedure row, test-dns's and test-tcp's rows |
| T8 | bodies that run at once not inlined | "rule 4's findings name each call…" |
| T9 | a verb misspelt (`uv-getaddrinfo`) | the liveness row |
| T10 | test-dns.sps dropped from the suite list | the liveness row, the completeness row |
| T11 | a re-raising clause still counted as containing | "rule 4 flags a verb…" |
| T12 | quasiquote skipped wholesale, as in the first version | the same |
| T13 | callbacks not collected | "rule 4's findings name each call…" |
| T14 | `uv-getaddrinfo!` dropped from the registering calls | "rule 4 flags a verb…", the callbacks row, the procedure row, the findings row |
| T15 | a verb passed as a value not flagged | "rule 4 flags a verb…" |
| T16 | procedure definitions read at top level only | the procedure row (a helper defined in a `with-loop` body) |
| T17 | import forms walked | "rule 4 flags a verb…", test-dns's row (its `only` import) |
| T18 | `error` not counted as raising again | "rule 4 flags a verb…" |
| T19 | `case-lambda` not read as a lambda | "rule 4 flags a verb…" (the case-lambda callback; the first run survived until that case was added) |
| T20 | a `case-lambda` definition not read as a procedure | "rule 4 flags a verb…", the procedure row |
| U1 | test-dns's v4 start back at top level | test-dns's rule-4 row |
| U2 | the same-turn cancel unguarded | the same |
| U3 | the synthetic sockaddr unguarded | the same |
| U4 | test-tcp's first bind unguarded | test-tcp's rule-4 row |
| U5 | `(h-submit! 1)` back at top level | test-dns's rule-4 row |
| U6 | the double-cancel attempt unguarded | the same |
| U7 | the in-flight start's `set!` moved out of its row | the same |
| U8 | `h-submit!`'s in-callback resubmission unguarded | the same |
| U9 | test-facade's first bind unguarded | test-facade's rule-4 row |
| U10 | test-facade's cancel unguarded | the same |
| U11 | test-flow's buffer-size bind unguarded | test-flow's rule-4 row |
| U12 | the teardown attempt swallows its raise instead of passing it on | nothing in `make test`: see below |

34 of 35 caught by name, the control green.

U12 changes only the failure path. The attempt then answers the handler's
value, and the retry loop reads it as an observation. Under F4 that ends
the suite. Rule 4 sees placement, not that, and no normal run takes the
path. The forced failures above are what hold it.

## The review (of a7095f0)

Confirmed by its verifiers, and fixed here:

1. `ftype-pointer` missing from rule 4's address family (S2d, S9b).
2. Rule 4's hand-picked suite list left out test-facade and test-flow, and
   had no completeness row (T10).
3. `h-submit!`'s resubmission from its own callback still ended test-dns:
   rule 4 treated every lambda as contained (F7, U8, T13).
4. A catch-all guard whose clause raises again counted as containing (T11,
   T18).
5. `chez_uv_constant`'s allowlisting rested on an unchecked comment (S1c,
   S29).
6. A function ftype bypassed rules 3 and 4 (S21, S23).
7. Lambdas that run at once, verbs passed as values, and helpers defined in
   a `with-loop` body escaped rule 4 (T4, T15, T16).
8. Quasiquote was skipped wholesale, and its `case-lambda` decisions were
   untested (T12, T19, T20).
9. A raised retry attempt left its lookups or its loop behind, and later
   rows failed blaming correct code (F5).
10. AGENTS.md and rule 4's header claimed more than the rule held, and the
    header put test-tcp's death at its first bind under MV1 as well as MA8.
11. A raised attempt read as a lost race in the display lines and catcher
    rows.
12. The close-after-drain row passed when no drain had run.
13. The FFI rule rows answered their offenders, but nothing printed them.
14. A test-tcp comment said failing rows print only their names.
15. This log's G7 row credited a row that did not catch it. The mutation
    that ran then counted calls of the first verb only. T7 is the faithful
    one.

Also from the review, done here: `uncaught` is `findings`. `chez-verdict`
reuses one environment; a fresh one per call kept about 55 KB each for
good, about 11 ms a run. The duplicate IPv6 bind row folded into the
original.

Left, as follow-ups:

- **The loopback fixtures.** Rule 4 does not follow `bind-loopback!` and
  `connect-loopback!`. The same scan with them as verbs finds 50 top-level
  fixture calls in seven suites: test-tcp 26, test-callback-alloc 6,
  test-flow 6, test-lifecycle 5, test-stream 3, test-echo 2, test-process
  2. #52's seed gates cover a handshake that never completes, not a bind
  that raises.
- **A runner-level backstop.** The review's altitude angle measured one.
  It is a launcher that sets Chez's `base-exception-handler` and runs each
  suite with `load-program`. It gives every suite a summary and exit 1 on
  an uncaught raise, the fixtures and callbacks included. Under F2 it gave
  test-tcp 24 passes and 7 failures, and normal results were unchanged in
  all 24 suites. Rows after the raise still do not run, so it complements
  rule 4 rather than replacing it. It needs the Makefile's suite recipes.
- **The failing-row hook** is now in fourteen suites, each a verbatim copy
  (nine on main).
- **Rule 4 reads placement, not dependence.** It cannot tell that a later
  form reads what a start answered. Those forms were found by the forced
  failures, which `make test` does not repeat.

## Gates

On the branch head (7626c78, cut from a473313):

- `make test`: 24 suites pass.
- `make check-purity`: green.
- `make check-memory-gate` + `make test-memory` (macOS ASan): green.

#67 and #69 landed on main meanwhile (2511d17), and the branch merges with
it cleanly. So every gate ran again on the planned merge, main plus this
branch (tree a6f6e43), in `--no-hardlinks` scratch clones:

- `make test`: 24 suites pass.
- `make check-purity`: green.
- `make check-memory-gate` + `make test-memory` (macOS ASan): green.
- `make test-memory-docker` (Linux Valgrind): green. All 24 suites have 0
  errors and 0 bytes definitely lost. The 76 forked children are the known
  fork artifacts.

#68 (#63's fix, which rewrites `process.sls`) landed next (5ac8469), and
the branch merges with it cleanly. That `process.sls` imports nothing from
`(chezscheme)` renamed or prefixed and makes no foreign call, so rule 5
holds over it. The macOS gates ran again on that merge (tree 9f03976):

- `make test`: 24 suites pass.
- `make check-purity`: green.
- `make check-memory-gate` + `make test-memory` (macOS ASan): green.

Linux Valgrind on that merge is left to CI, which runs on the merge with
main.
