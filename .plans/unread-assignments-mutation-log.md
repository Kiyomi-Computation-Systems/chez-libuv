# Variables the tests assign and never read (#89): evidence and mutation log

2026-10-09. test-tcp.sps's `graise-peer` was set by an accept callback and
listed in test-seed-gates.sps's peer census, and no row read it (#89). A
review found it. A probe of every file under `tests/` found more of the
same shape, so, at the user's choice, the fix is a rule that fails any
such variable, plus a fix for each one found. The rule is
`tests/test-unread-assignments.sps`, a pure suite. It reads every `.sps`
and `.sls` file directly under `tests/`.

## What the probes found

- **By name.** A variable assigned in a file and mentioned nowhere else
  outside quoted data: seven. They were `graise-peer`, `graise-conn` and
  `pending-conn` (test-tcp), `w-peer` (test-lifecycle), `f-eof`
  (test-facade), `eof-mark` (test-signal) and `trunc-neighbours`
  (test-addrinfo).
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
| `w-peer` | test-lifecycle | the request-block section's accepted peer | deleted; the callback accepts into nothing. The suite's seed-gates entry loses its `never-accepted` spelling, which nothing in it uses now |
| `pending-conn` | test-tcp | the pending-write section's listen status | evidence: its seed row answers it, with the connect status, when the wait gives up |
| `eof-mark` | test-signal | how the E2E child's pipe ended | evidence: the transcript row answers it with a short transcript. test-signal now prints a failing row's actual, as test-tcp does; before, the E2E rows' exit payloads were never printed either |
| `f-eof` | test-facade | the peer's on-eof, beside on-data and on-error, which rows read | rows, in a reordered chain (below) |
| `trunc-neighbours` | test-addrinfo | strings allocated after the sweep's collection | deleted, with the allocation: measured, below |
| `spray` | test-native | bytevectors filling the heap after the scan's collection | deleted, with the fill: measured, below |

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

### The facade's chain, reordered

The PR's first version waited in the drain for EOF and then asserted it.
That broke the next row, "uv-read-stop! is re-exported and stops a
running read". libuv ends a read at EOF: `uv__stream_eof` clears
`UV_HANDLE_READING` (`vendor/libuv/src/unix/stream.c:931-937`), and
`uv_read_stop` on a stream that isn't reading returns 0 at once
(`stream.c:1473-1475`). So the row stopped nothing and still passed.
Without the EOF wait, the drain stopped before EOF in 200 of 200 runs, so
on main the row did stop a running read, though nothing checked that.

The chain is now:

1. The client writes, and the first drain waits for the write, the accept
   and the payload. No FIN has been sent, so the read is running.
2. "uv-read-stop! is re-exported and stops a running read" stops it. If EOF
   had already arrived, the row answers `(read-had-ended …)` instead.
3. "uv-shutdown! is re-exported and starts the client's shutdown". A drain
   then waits for its completion.
4. "the stopped read delivered no EOF while the client shut down". This is
   one-sided: a correct build never delivers EOF to a stopped read.
5. "uv-read-start! restarts the stopped read". A drain waits for EOF.
6. "the client's shutdown ended the restarted read through on-eof", and
   "the restarted read fired no error callback".

Under an 8-pair loopback flood (the generator in
`.plans/reset-precondition-mutation-log.md`), at load up to 54, 40 runs of
the reordered chain all passed. Each drain's cap is 4,000 steps:

| Drain | Median | p90 | Max |
|---|---|---|---|
| write, accept and payload | 206 | 466 | 770 |
| the shutdown's completion | 1 | 1 | 1 |
| the restarted read's EOF | 10 | 87 | 330 |

For comparison, the first version's single drain, which waited for EOF,
took at most 1,312 steps under the same flood. Main's, alternated with it
run by run at load up to 31, took at most 1,878.

### The two fills were dead

Each fill exists for a sweep that catches a copy reading past a truncated
object. Each sweep's own source mutant was run with the fill as it was,
with the values allocated but not stored, and with no allocation at all:

- **test-addrinfo**: MC2 of `.plans/getaddrinfo-snapshot-mutation-log.md`,
  `read-utf8` copying without disabling interrupts.
- **test-native**: M10 of `.plans/write-copy-leak-mutation-log.md`, the span
  check moved out of the interrupt-free step.

| Sweep under its mutant | macOS arm64 (5 runs each) | Linux arm64, Ubuntu 26.04, libuv 1.51.0 (3 runs each) |
|---|---|---|
| addrinfo, stored / unstored / no allocation | fails 5/5 each, 64 bad runs every time | fails 3/3 each |
| native, stored / unstored / no fill | fails 5/5 each, the same outcomes | fails 3/3 each |
| correct build, no allocation | passes 5/5 (both suites) | passes 3/3 (both suites) |

Neither sweep needs its fill. The first version of this PR exempted both
variables, saying their stores kept their values alive. That was not
measured, and it was wrong.

## RED

- **Against a stub.** With the walk answering `'()` and the source test
  `#f`, every rule row failed by name. The seeded rows answered all-empty
  actuals, and the real-files row `()`.
- **With the walk, before the fixes.** The real-files row failed with the
  eight variables above.
- **Moving the lister and reader into `(uv-source)`.** test-sweep's census,
  widened to `(uv-source)`'s exports, failed on test-seed-gates' copies:
  `(test-sources "tests/test-seed-gates.sps" "tests/uv-source.sls")` and
  `(read-forms "tests/test-seed-gates.sps" "tests/uv-source.sls")`.
- **After the deletions.** test-seed-gates' census rows (placeholders, and
  what accepted peers set) failed for test-tcp and test-lifecycle until
  their lists were updated.
- **The macro-body case.** `(with-mutex m (define x 2) x)` failed with
  `()` until the walk read an unknown form's arguments as a body.

## Mutations

Each mutant is an exact, single-match replacement in a copy of `src/` and
`tests/` outside the repo. It is run with `CHEZSCHEMELIBDIRS` pointing at
the copy, and the source-reading suites run from the copy's root. There
were 56 mutants on the final tree, and every one failed. Each failed the
row named below, with the actual shown.

Row names, shortened: **flags** "a variable assigned and never read is
flagged, and only that"; **scope** "a read counts only for the binding in
scope"; **templates** "a syntax-rules template is read for the names it
mentions, and nothing more"; **sources** "the sources read are every .sps
and .sls file directly under tests/, and no other file"; **unreadable** "a
file the walk cannot read is named, with what was raised"; **seed** "the
walk sees both procs test-process.sps assigns, and that each is read";
**real** "no file directly under tests/ assigns a variable it never
reads". In the flags, scope and templates actuals, the case that changed
is named by its position, counting from 1.

### The walk (test-unread-assignments)

| ID | Mutation | Killed by |
|---|---|---|
| W1 | a quoted mention counts as a read | flags, case 4: `()`; seed `#f`; real names each file the walk now raises on, e.g. `("tests/test-addrinfo.sps" (raised "~s is not a proper list" (inet6)))` |
| W2 | a read inside the variable's own set! counts | flags, case 5: `()` |
| W3 | a lambda in the variable's own set! does not end the exemption | flags, case 6: `(x)`; seed `((proc . #t) (proc . #f))`; real `(("tests/test-process.sps" proc))` |
| W4 | a quasiquote's unquoted parts are not read | flags, case 7: `(x)` |
| W5 | a quasiquote is read whole | flags, case 8: `()` |
| W5b | an unquote inside a quasiquoted vector is not read | flags, case 9: `(x)` |
| W6 | an import form's names count as reads | flags, case 10: `()` |
| W7 | a set! of a name bound outside the file is taken as a variable | flags `#f` (raised) |
| W8 | names matched without scope | scope (15 cases change), templates, seed `((proc . #t))` |
| W9 | let* and let*-values bind like let | scope, cases 8 and 14: `()`; real adds `stop`, `go`, `args` in test-native, test-process and test-stream |
| W9b | let*-values read like let-values | scope, case 14: `()` |
| W10 | let's inits read inside its scope | scope, case 9: `(a)` |
| W11 | letrec's inits read outside its scope | scope, case 10: `()` |
| W12 | a named let's name binds nothing | scope, case 11: `()` |
| W13 | a named let's inits read inside its scope | scope, case 12: `(i)` |
| W14 | let-values binds nothing | scope, case 13: `()` |
| W15 | do binds nothing | scope, case 15: `()` |
| W16 | do's inits read inside its scope | scope, case 16: `(i)` |
| W17 | guard's variable binds nothing | scope, case 17: `()` |
| W18 | guard's body read inside its variable's scope | scope, case 18: `(e)` |
| W19 | case's datums count as reads | scope, case 19: `()`; real names the file that raised |
| W22 | a record type's field names count as reads | scope, case 20: `()` |
| W23 | a record type's protocol is not read | scope, case 21: `(a)` |
| W25 | an improper formals list's rest name binds nothing | scope, case 6: `()` |
| W26 | only the file's top level binds its definitions | scope, cases 3, 4, 5, 22 and 23; seed `()` |
| W27 | a begin's definitions bind nothing | scope, case 4: `()` |
| W28 | define-values binds nothing | scope, case 5: `()` |
| W29 | a procedure definition's parameters bind nothing | scope, case 1: `()` |
| W30 | case-lambda's formals bind nothing | scope, case 7: `()` |
| W34 | an unknown form's arguments read without a body's scope | scope, cases 22 (library) and 23 (with-mutex): `()` |
| W35 | a variable read only as an operator is not read | flags, case 3: `(f)`; real adds `early`, `forged`, `cleared` (test-loop-claim), `resume-k` (test-loop), and more |
| T1 | a syntax-rules pattern binds nothing in its template | templates, cases 1 and 8: `()` |
| T2 | templates are not read | templates, cases 2, 5 and 6: `(a)` |
| T3 | templates taken apart as code (this PR's first version) | templates `#f` (raised) |
| T4 | a template's quoted parts count as reads | templates, case 7: `()` |
| T5 | a pattern's vector binds nothing | templates, case 8: `()` |
| T6 | a template's vector counts as reads | templates, case 9: `()` |
| G1 | no guard around one file's walk | unreadable `#f` |

### `(uv-source)`'s moved helpers, against every suite that uses them

| ID | Mutation | test-unread-assignments | test-sweep | test-seed-gates |
|---|---|---|---|---|
| U1 | a dotfile counts as a source | sources: `".#a.sps"` taken | survives: `tests/` holds no dotfile | survives: reads no listing |
| U2 | a library source is not one | sources | its engine census and its definition census | survives, the same |
| U3 | a name shorter than its suffix is read past | sources `#f` (raised) | survives: `tests/` here holds none | survives, the same |
| U4 | read-forms keeps only the first datum | the seed: `()` (the real-files row passes; the seed is why it is there) | the engine census | 19 rows |
| U5 | test-sources finds nothing | sources | both censuses | survives, the same |

In this checkout, `tests/tmp` exists (gitignored). Under U3's shape the
first version's suite died outside any row, with exit 255 and "Exception in
substring: -1 and 3 are not valid start/end indices for "tmp"". The listing
is now called inside rows.

### The variables, put back or no longer read

| ID | Mutation | Killed by |
|---|---|---|
| R1 | `graise-peer` put back | real: `(("tests/test-tcp.sps" graise-peer))` |
| R2 | `graise-conn` put back | real: `(("tests/test-tcp.sps" graise-conn))` |
| R3 | the seed row no longer answers `pending-conn` | real: `(("tests/test-tcp.sps" pending-conn))` |
| R4 | `w-peer` put back | real: `(("tests/test-lifecycle.sps" w-peer))` |
| R6 | the transcript row no longer answers `eof-mark` | real: `(("tests/test-signal.sps" eof-mark))` |
| R7 | `trunc-neighbours` put back | real: `(("tests/test-addrinfo.sps" trunc-neighbours))` |
| R8 | `spray` put back | real: `(("tests/test-native.sps" spray))` |

### The facade's chain and the evidence rows

| ID | Mutation | Killed by |
|---|---|---|
| F1 | src: the EOF dispatch never calls on-eof (`handles.sls`) | "the client's shutdown ended the restarted read through on-eof": `on-eof-never-fired` |
| F2 | src: `uv-read-stop!` never calls `uv_read_stop` (`stream.sls`) | 10 of 10 runs, by one of two rows. In 3, "the stopped read delivered no EOF while the client shut down" answered `eof`. In 7, "uv-read-start! restarts the stopped read" answered `(raised "Exception in uv-read-start!: connection already in progress")`: the read had never stopped |
| F3 | the first version's order: shutdown from the write's completion, and the first drain waits for EOF | "uv-read-stop! … stops a running read": `(read-had-ended eof)` |
| F4 | no wait for the restarted read's EOF | the restarted-read EOF row: `on-eof-never-fired` |
| F5 | the restarted read's on-eof records nothing | the same |
| E1 | test-signal: the child's output is never collected | the transcript row: `("" pipe eof)` |
| E2 | test-tcp: the pending-write server never accepts | its seed row: `(iterations-exhausted listen #f connect #f)` |

## Limits

- **What the walk reads.** It reads the binding forms in the suite's
  header. A binding form outside that list counts its names as reads, and
  what a macro use binds is not seen, so a `set!` of it is ignored. A
  syntax-rules template's own definitions are not taken apart. Each of
  these can hide a finding.
- **Things that would only matter for code that doesn't compile.** These
  are the `(pair? (cdr f))` checks in `body-names` and the walk's body
  forms, and they were not mutated. A quasiquote inside a template, or a
  template naming an outer variable only inside a vector, would also be
  misread.
- **The rule's reach.** It covers files directly under `tests/`. `src/` is
  outside it. The walk raised on `src/libuv/private/handles.sls` before
  templates were read for their names only.

## Gates

- `make test` and `make check-purity` on the final tree, and again on its
  merge with main at 5e2a832 (#120, #121, #122). Rule 5 and the widened
  census read the new `tests/test-loop-guard.sps` and `tests/uv-child.sls`
  there.
- Linux aarch64 (Ubuntu 26.04, libuv 1.51.0, in Docker): the two fills'
  measurements above.
- CI's first run on this PR failed in test-dns's queued-tail teardown,
  which this PR doesn't touch. That row races a lookup cancel against a
  one-worker pool, and it lost all 16 of its draws. Main's run an hour
  before, on the same runner image and libuv, won on the first draw. On
  macOS, 60 runs on this branch all won: 57 on the first draw, 2 on the
  second and 1 on the third.
