# Variables the tests assign and never read (#89): evidence and mutation log

2026-10-09. test-tcp.sps's `graise-peer` was set by an accept callback and
listed in test-seed-gates.sps's peer census, and no row read it (#89). A
review found it. A probe of every file under `tests/` found more of the
same shape, so, at the user's choice, the fix is a rule that fails any
such variable, plus a fix for each one found. Rule 5 of
`tests/test-seed-gates.sps` holds every `.sps` and `.sls` file directly
under `tests/` to it.

## What the probes found

- **By name.** A variable assigned in a file and mentioned nowhere else
  outside quoted data: seven. They were `graise-peer`, `graise-conn` and
  `pending-conn` (test-tcp), `w-peer` (test-lifecycle), `f-eof`
  (test-facade), `eof-mark` (test-signal) and `trunc-neighbours`
  (test-addrinfo). Nothing in `src/` matched.
- **Why the rule reads scope.** A rule by name misses an unread variable
  wherever its name is read in another binding in the same file. 40
  assigned names are bound in more than one place. `proc` is bound 19 times
  in test-process.sps, and `eof` and `exit-result` 8 times each.
- **By scope.** An eighth: test-native's `spray`. The probe by name had
  counted its own `let` binding as a read.
- **One false positive, fixed by the lambda exemption.** test-process.sps's
  `proc` in the close-from-on-exit section is read only in the on-exit
  callback, inside its own `set!`'s value. That callback runs later and
  reads the stored process, so a lambda ends the exemption for reads inside
  a variable's own assignment.

## What each became

| Variable | File | What it held | Now |
|---|---|---|---|
| `graise-peer` | test-tcp | the raise section's accepted peer | deleted; the callback accepts into nothing |
| `graise-conn` | test-tcp | that section's listen status | deleted |
| `pending-conn` | test-tcp | the pending-write section's listen status | deleted. Its seed row already requires the peer, which only a listen that succeeded stores |
| `w-peer` | test-lifecycle | the request-block section's accepted peer | deleted; the callback accepts into nothing. The suite's seed-gates entry loses its `never-accepted` spelling, which nothing in it uses now |
| `eof-mark` | test-signal | the E2E child pipe's EOF or error | deleted |
| `f-eof` | test-facade | the peer's on-eof, beside on-data and on-error, which rows read | a new row, "the client's shutdown ended the peer's read through on-eof", and the drain waits for it |
| `trunc-neighbours` | test-addrinfo | strings kept next to the string the sweep truncates | kept, listed in `kept-alive` |
| `spray` | test-native | the bytevectors that fill the heap | kept, listed in `kept-alive` |

### Why `graise-peer` got no row

The section's shape, in a loop (macOS arm64, idle, 2,000 rounds):

| Order of callbacks | Rounds |
|---|---|
| connect, connection, write (raise) | 1,651 |
| connect, write (raise): no connection callback before `uv-run` raised | 347 (17%) |
| connection, connect, write (raise) | 2 |

A row on the peer would fail a correct build about one run in six. The
section's two rows check the write's raise and the freed write block,
and neither depends on the peer.

### The facade drain waits for EOF

- Without the wait, with the row: the row failed in **200 of 200** runs with
  `on-eof-never-fired`. The drain always stopped before EOF arrived.
- With it: 0 of 200, idle.
- Under an 8-pair loopback flood (the generator in
  `.plans/reset-precondition-mutation-log.md`), at load up to 15: 60 runs,
  all passed. The drain took a median of 223 steps and at most 1,304,
  against a cap of 4,000.
- A/B under a fresh flood, at load up to 31, alternating run by run, 50
  each:

  | Drain condition | Passed | Median | p90 | Max |
  |---|---|---|---|---|
  | main's (no EOF wait) | 0 (the EOF row fails) | 102 | 519 | 1,878 |
  | with the EOF wait | 50 | 142 | 439 | 1,312 |

  The EOF wait is not what makes the tail.

## RED

- **Against a stub.** With `unread-assignments` answering `'()` and
  `test-source?` `#f`, all four rule-5 rows failed by name. The seeded rows
  answered all-empty actuals, the files row `((#f #f #f #f) (#f …))`, and
  the real-files row `()`.
- **With the walk, before the fixes.** The real-files row failed with
  `(("tests/test-addrinfo.sps" trunc-neighbours) ("tests/test-facade.sps" f-eof)
  ("tests/test-lifecycle.sps" w-peer) ("tests/test-native.sps" spray)
  ("tests/test-signal.sps" eof-mark)
  ("tests/test-tcp.sps" pending-conn graise-conn graise-peer))`.
- **After the deletions.** test-seed-gates' census rows (placeholders, and
  what accepted peers set) failed for test-tcp and test-lifecycle until
  their lists were updated.
- **The macro-body case.** `(with-mutex m (define x 2) x)` failed with
  `()` until the walk read an unknown form's arguments as a body.

## Mutations

Each mutant is an exact, single-match replacement in a copy of `src/` and
`tests/` outside the repo. It is run with `CHEZSCHEMELIBDIRS` pointing at
the copy, and test-seed-gates runs from the copy's root. There were 43
mutants, and every one failed. Each failed the row named below, with the
actual shown, on the final tree.

Row names, shortened: **flags** is "rule 5 flags a variable that is
assigned and never read, and only that"; **scope** is "rule 5 counts a
read only of the binding in scope"; **files** is "rule 5 reads every .sps
and .sls file directly under tests/, and no other file"; **real** is
"every variable a file in tests/ assigns is read, but the two kept only to
keep their values alive". In the flags and scope actuals, the case that
changed is named by its position, counting from 1.

### The walk

| ID | Mutation | Killed by |
|---|---|---|
| W1 | a quoted mention counts as a read | flags, case 4: `()`; real: `#f` |
| W2 | a read inside the variable's own set! counts | flags, case 5: `()`; scope, case 21 (a template's counter): `()` |
| W3 | a lambda in the variable's own set! does not end the exemption | flags, case 6: `(x)`; real: adds `("tests/test-process.sps" proc)` |
| W4 | a quasiquote's unquoted parts are not read | flags, case 7: `(x)` |
| W5 | a quasiquote is read whole | flags, case 8: `()` |
| W6 | an import form's names count as reads | flags, case 9: `()` |
| W7 | a set! of a name bound outside the file is taken as a variable | flags: `#f` (raised) |
| W8 | names matched without scope: the first binding of a name stands for all | scope: 15 of 25 cases change |
| W9 | let* binds like let | scope, case 8: `()`; real: adds `stop`, `go`, `args` in test-native, test-process and test-stream |
| W10 | let's inits are read inside its scope | scope, case 9: `(a)` |
| W11 | letrec's inits are read outside its scope | scope, case 10: `()` |
| W12 | a named let's name binds nothing | scope, case 11: `()` |
| W13 | a named let's inits are read inside its scope | scope, case 12: `(i)` |
| W14 | let-values binds nothing | scope, case 13: `()` |
| W15 | do binds nothing | scope, case 14: `()` |
| W16 | do's inits are read inside its scope | scope, case 15: `(i)` |
| W17 | guard's variable binds nothing | scope, case 16: `()` |
| W18 | guard's body is read inside its variable's scope | scope, case 17: `(e)` |
| W19 | case's datums count as reads | scope, case 18: `()`; real: `#f` |
| W20 | a syntax-rules pattern binds nothing in its template | scope, case 19: `()` |
| W21 | syntax-rules templates are not read | scope, cases 20 and 21: `(a)`, `()` |
| W22 | a record type's field names count as reads | scope, case 22: `()` |
| W23 | a record type's protocol is not read | scope, case 23: `(a)` |
| W25 | an improper formals list's rest name binds nothing | scope, case 6: `()` |
| W26 | only the file's top level binds its definitions | scope, cases 3, 4, 5, 21, 24 and 25 |
| W27 | a begin's definitions bind nothing | scope, cases 4 and 21: `()` |
| W28 | define-values binds nothing | scope, case 5: `()` |
| W29 | a procedure definition's parameters bind nothing | scope, case 1: `()` |
| W30 | case-lambda's formals bind nothing | scope, case 7: `()` |
| W31 | a dotfile counts as a source | files: `".#a.sps"` taken |
| W32 | a library source is not read | files: `tests/uv-testing.sls` and `"a.sls"` dropped |
| W33 | a name shorter than its suffix is read past | files: `#f` (raised) |
| W34 | an unknown form's arguments are read without a body's scope | scope, cases 24 (library) and 25 (with-mutex): `()` |
| W35 | a variable read only as an operator is not read | flags, case 3: `(f)`; real: adds `early`, `forged`, `cleared` (test-loop-claim), `resume-k` (test-loop), and more |
| K1 | `spray` dropped from `kept-alive` | real: still finds it |

- **W1 and W19** also fail the real-files row with `#f`. Read as code,
  quoted data and `case` datums hold shapes the `let` clauses cannot take
  apart. The raise is caught inside the row.
- **W33** answers `#f` in the mutant's copy, which has no `tests/tmp`. In
  this checkout `tests/tmp` exists (gitignored), and under W33 the suite
  died at `test-sources`, outside any row: exit 255, "Exception in
  substring: -1 and 3 are not valid start/end indices for "tmp"".
- **W24** (a library form's body is not entered) survived once the `else`
  read an unknown form's arguments as a body. That reads a library form the
  same way, so the special case was removed, and W34 holds the library case.
- **The walk once had a clause** for a definition reached outside a body it
  knows. A probe of every file found none, so it handled nothing. Reading an
  unknown form's arguments as a body replaced it (W34).

### The fixes

| ID | Mutation | Killed by |
|---|---|---|
| R1 | `graise-peer` put back | real: `("tests/test-tcp.sps" graise-peer)`; the census rows too |
| R2 | `graise-conn` put back | real: `("tests/test-tcp.sps" graise-conn)` |
| R3 | `pending-conn` put back | real: `("tests/test-tcp.sps" pending-conn)` |
| R4 | `w-peer` put back | real: `("tests/test-lifecycle.sps" w-peer)`; the census rows too |
| R5 | the facade's EOF row and wait taken away | real: `("tests/test-facade.sps" f-eof)` |
| R6 | `eof-mark` put back | real: `("tests/test-signal.sps" eof-mark)` |
| F1 | src: the EOF dispatch never calls on-eof (`handles.sls`) | test-facade: the EOF row alone, `on-eof-never-fired` (76 pass) |
| F2 | the drain stops before EOF arrives | test-facade: the EOF row, `on-eof-never-fired` |

## Limits

- **Expansions are not followed.** A name that a macro use binds is not
  seen, so a `set!` of it is ignored. A binding form outside the rule's list
  counts its names as reads, and `fluid-let` is read as a call. Each of
  these can only hide a finding; none can add one.
- **Some checks only matter for code that would not compile.** They are
  the `(pair? (cdr f))` checks in `body-names` and `walk-form`, and they
  were not mutated.
- **The rule's reach.** It reads files directly under `tests/`. `src/` is
  outside it.

## Gates

- `make test` and `make check-purity` on the final tree.
- The open PRs' test files, overlaid on this branch: #120
  (`fix/guard-reraise-118`, a45fcad) and #122
  (`test/stranded-child-runner-117`, 988e02d). test-seed-gates passed 95
  rows on each. Neither PR touches a file this branch changes.
