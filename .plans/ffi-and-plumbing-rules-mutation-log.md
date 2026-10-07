# Two FFI source rules, and the address verbs out of suite plumbing: mutation log

Issue #64, items 2 and 5. Branch `test/ffi-rules-and-dns-plumbing`, from
`main` at a473313. Chez 10.4.1 on macOS arm64.

Test-only, apart from comments in `src/libuv/private/native.sls`. No shim
change, and no release note.

## Item 2: what Chez does with each argument type

Two invariants lived only in `native.sls`'s comments: no caller's string
crosses the FFI as a `string` argument, and no `u8*` goes to a
`__collect_safe` call. The review asked for each rule to name its whole
family of types. Expanding `(foreign-procedure conv "strlen" (T) void)` under
a lambda that never runs, for each candidate T:

| type | plain call | `__collect_safe` |
|---|---|---|
| `string` `wstring` `utf-8` `utf-16` `utf-16le` `utf-16be` `utf-32` `utf-32le` `utf-32be` | accepted | refused: "string argument not allowed with __collect_safe procedure" |
| `u8*` `u16*` `u32*` `scheme-object` `ptr` `ftype-scheme-object-pointer` | accepted | accepted |
| scalars (`uptr`, `int`, `size_t`, …) | accepted | accepted |
| `bogus-type` | "invalid foreign-procedure argument type specifier" | the same |

- `ptr` is `scheme-object`: the fixnum 5 crosses as 40, and a bytevector as
  its tagged address, through either.
- `ftype-scheme-object-pointer` takes `(make-ftype-scheme-object-pointer obj
  offset)`, a Scheme object's address plus an offset. A `(* ftype)` or
  `(& ftype)` parameter refuses such a pointer at the call ("invalid
  foreign-procedure argument"), so ftype pointers stay out of the family.
- Chez refuses every string type under `__collect_safe` itself, so rule 4
  names only the address family.

The suite asks the same expander, so a misspelt family member, or a Chez
that stops refusing strings under `__collect_safe`, fails a row by name.

On a473313 the scan finds 110 foreign calls, all in `native.sls` (one is
`shim-procedure`'s template): one string argument (`chez_uv_constant`), eight
`u8*` bindings (`chez_uv_copy_in`, `chez_uv_copy_out`, `uv_strerror_r`,
`uv_err_name_r`, `uv_ip4_addr`, `uv_ip6_addr`, `uv_getaddrinfo`,
`uv_ip_name`) and one `__collect_safe` call (`uv_run`). The three comments
covered five of the eight.

### Mutations (`tests/test-source-rules.sps`)

Each ran in a fresh copy of `src/` and `tests/` outside the repo; every edit
had to match exactly once.

| id | mutation | fails by name |
|---|---|---|
| R0 | none (control) | nothing: 16 pass |
| R1 | `uv_ip4_addr` takes `string` | "a string crosses the FFI only into chez_uv_constant…" |
| R1b | `uv_ip6_addr` takes `utf-8` | the same |
| R1c | `chez_uv_errno_name` (a `shim-procedure`) takes `wstring` | the same |
| R2 | `uv_strerror_r` marked `__collect_safe` | "no __collect_safe foreign call in src/ takes an argument in Scheme memory" |
| R2b | `uv_getaddrinfo` marked `__collect_safe` | the same |
| R2c | `uv_run` takes `scheme-object` | the same |
| R3 | the allowlist emptied | "a string crosses the FFI only into chez_uv_constant…" |
| R4 | the scan ignores `shim-procedure` forms | the scan's liveness row, the string rule, the string seeded row |
| R5 | the scan looks for `collect_safe` | the liveness row, the collect-safe seeded row |
| R6 | the scan reads the result type as a parameter | the string seeded row |
| R7 | the scan counts `foreign-callable` forms as calls | both seeded rows |
| R8 | `utf-16le` dropped from the string family | the string seeded row |
| R9 | `ptr` dropped from the address family | the collect-safe seeded row |
| R10 | `utf-8` misspelt `utf8` | the string seeded row, "Chez encodes each string type…" |
| R11 | `ftype-scheme-object-pointer` misspelt | the collect-safe seeded row, "Chez accepts each address type…" |
| R12 | the verdict matches a shorter refusal message | "Chez encodes each string type…" |
| R13 | the verdict drops the convention | the same |
| R14 | the verdict's environment lacks `foreign-procedure` | the verdict's control row and both Chez rows |
| R15 | `__collect_safe` seen only as the first convention | the collect-safe seeded row (its `(__varargs_after 1) __collect_safe` call) |
| R16 | `uv_run` loses `__collect_safe` | the liveness row |
| R17 | the scan reads only the first parameter | both seeded rows |

21 of 21 caught by name, the control green.

## Item 5: verbs that end a suite when they raise

### The scan

The issue counted 19 top-level lookups in `test-dns.sps` and the review 4
top-level binds in `test-tcp.sps`, reading direct calls. Rule 4
(`tests/test-seed-gates.sps`) reads further. A call is contained in a row's
tested expression, in a procedure body, or in the body of a guard with an
`else` or `#t` clause. A suite procedure whose body such a raise can leave
counts as a verb. The verbs are `uv-getaddrinfo!`, `uv-getnameinfo!`,
`uv-cancel!`, `uv-tcp-bind!`, `uv-tcp-connect!` and `fill-sockaddr!`.

On a473313 it fails `test-dns.sps` with 24 findings and `test-tcp.sps` with
2. `test-address.sps` passes (its one bind is already guarded):

- `test-dns.sps`: the 19 direct calls; `(h-submit! 1)`; the synthetic
  sockaddr (`make-synthetic-sockaddr` calls `fill-sockaddr!`); the
  same-turn `(uv-cancel! tc-tail-req)`; the double-cancel and teardown
  retry loops (`double-cancel-attempt!`, `teardown-attempt!`).
- `test-tcp.sps`: the binds at lines 178 and 216. The review's other two
  (`rp-flagged-bind`, `rp-second-same-port`) were already inside `#t`
  guards, and `bind-a-fixed-port` guards its own bind.

Each start now runs in a row's tested expression, inside a catch-all guard
that answers `(raised description)`. test-tcp gained the same hook test-dns
and test-address have, which prints a failing row's actual value. Values the
plumbing reads later start as a placeholder (`'never-started`). Each form
that would raise on that placeholder is gated: the port read after a bind,
the synthetic node's address and its `free!`, the drain on a loop the EBUSY
row closed. A raising retry attempt ends its loop and is reported by a row of
its own.

### Forced failures, main's suites against these

Each verb was made to raise in a scratch copy of `src/`. Main's
`tests/` (a473313) and this branch's ran against the same copy:

| id | planted failure | main: test-dns | branch: test-dns | main: test-tcp | branch: test-tcp |
|---|---|---|---|---|---|
| F1 | MA8: `c-string-bytes` drops the terminator | exit 255, no summary | exit 1: 50 pass, 99 fail | exit 255 | exit 255 at its first loopback fixture |
| F2 | `fill-sockaddr!` refuses every address | exit 255 | exit 1: 111 pass, 38 fail | exit 255 | exit 255 at its first loopback fixture |
| F3 | `uv-getaddrinfo!` raises on entry | exit 255 | exit 1: 67 pass, 82 fail | | |
| F4 | `uv-getnameinfo!` raises on entry | exit 255 | exit 1: 108 pass, 41 fail | | |
| F5 | `uv-cancel!` raises on entry | exit 255 | exit 1: 137 pass, 12 fail | | |
| F6 | IPv6 parsing refused | exit 255 | exit 1: 145 pass, 4 fail | exit 255 | exit 1: 236 pass, 3 fail |

Each failing start row carries its condition, for example
`(raised "… &uv-invalid-argument who: uv-getaddrinfo! reason: planted")`.

### Mutations (rule 4)

| id | mutation | fails by name |
|---|---|---|
| G0 | none (control) | nothing: 67 pass |
| G1 | rows not treated as containing their tested expression | the seeded rows, test-tcp's row (test-dns's starts sit in catch-all guards too) |
| G2 | any guard treated as catching everything | "rule 4 flags a verb…" |
| G3 | a catch-all guard's body walked | the seeded rows, all three suites' rows |
| G4 | lambdas walked | "rule 4 flags a verb…", the procedure row |
| G5 | quoted data walked | "rule 4 flags a verb…", test-dns's and test-tcp's rows |
| G6 | procedures found in one pass, not to a fixpoint | "a procedure a raise from a verb can leave counts as one, through another too" |
| G7 | a procedure counted by any call, guarded or not | the same, and the liveness row |
| G8 | bodies that run at once not inlined | "rule 4's findings name each call…" |
| G9 | a verb misspelt (`uv-getaddrinfo`) | the liveness row |
| G10 | test-dns.sps dropped from the suite list | the liveness row |
| H1 | test-dns's v4 start moved back to top level | test-dns's rule-4 row |
| H2 | the same-turn cancel unguarded | the same |
| H3 | the synthetic sockaddr unguarded | the same |
| H4 | test-tcp's first bind unguarded | test-tcp's rule-4 row |
| H5 | `(h-submit! 1)` back at top level | test-dns's rule-4 row |
| H6 | the double-cancel attempt unguarded | the same |
| H7 | the in-flight start's `set!` moved out of its row | the same |

17 of 17 caught by name, the control green.

## Left, not fixed here

- **The loopback fixtures.** Under F1 and F2, test-tcp now fails its two
  bind rows by name and then dies at its first `bind-loopback!`. The review
  took the four binds for how test-tcp died under MA8. They were only the
  first of many. The same scan, with `bind-loopback!` and
  `connect-loopback!` as its verbs, finds 49 top-level fixture calls in seven
  suites: test-tcp 26, test-callback-alloc 6, test-flow 6, test-lifecycle
  4, test-stream 3, test-echo 2, test-process 2. #52's seed gates cover a
  handshake that never completes, not a bind that raises.
- **Rule 4 reads placement, not dependence.** It cannot tell that a later
  form reads what a start answered. Those forms were found by the forced
  failures above, and `make test` does not repeat them.

## Gates

- `make test`: 24 suites pass.
- `make check-purity`: test-source-rules and test-seed-gates pull in no
  native code. The expander rows compile forms they never run.
