# A failed loopback seed fails test-tcp.sps by name: mutation log

Evidence for `test/tcp-seed-gates`, built on `main` at a0ea0ca and then
rebased onto 309c376, #48's squash ("Rebased onto #48", below). The change is
test-only: `tests/test-tcp.sps`, a new pure suite `tests/test-seed-gates.sps`,
and that suite's entry in the Makefile's `PURE_TESTS`.

Every probe and mutation ran in a `--no-hardlinks` clone of the worktree,
outside the repo, with its own build. Each plant was an exact,
whitespace-tolerant text replacement that aborts unless its target matches
exactly once, and every plant was validated before any ran. The clone's file
was restored after each run. Platform: macOS arm64 26.6.2, Chez 10.4.1
(`tarm64osx`), libuv 1.52.1 from pkg-config, the dev build. The machine was
shared with other sessions' test runs, at load averages from ~7 to ~158;
the sections below say which runs were under heavy load. The #50 session's
notes put deliberate loopback floods at 05:19–05:51 and 05:54–06:30 local
that day, to reproduce the reset section's flake, and record 0 failures in
400 test-tcp runs under CPU load alone (load average up to 106). The RED
sweep and the first green sweep ran inside the second window; the final
green sweep ran after it.

---

## The defect

Observed 2026-10-06 at load ~120: `tests/test-tcp.sps` printed FAIL rows for
"the peer's on-data callback delivered the client's write", "seed: the first
read-start allocated exactly one read buffer" and "a started read records
that the handle is reading", then died with exit 255 before every later row
and the SRFI-64 summary:

```
Exception in stream-read-buf: never-accepted is not of type #<record type uv-stream-record>
```

Each loopback section starts its peer as a placeholder, `(define s-peer
'never-accepted)`, which the server's accept callback replaces. The read
path's wait gave up at its cap of 64 ticks before the accept ran, and the
plumbing after the rows, `(define s-buffer-before-cycles (stream-read-buf
s-peer))` from v0.3 (51e56e1), handed the placeholder to a verb outside every
row. AGENTS.md names the trap: an unguarded raise in suite plumbing between
rows aborts the suite and destroys the evidence.

## Five shapes, each measured

The audit covered all twelve placeholders: `accepted`, `pa-peer`,
`pending-peer`, `q-peer`, `graise-peer`, `s-peer`, `m-peer`, `b-peer`,
`x-peer`, `wv-peer`, `rt-peer` and `ka-peer`. A failed seed cost the suite
its summary in five ways:

1. **A top-level call on a placeholder**: `pa-peer` (one read start),
   `s-peer` (the define above and nine more calls: read stop, the 50-cycle
   loop, the EOF read start, three direct read-dispatcher calls, two
   `set-handle-state!`, the alloc-dispatcher call), `b-peer` (the restart)
   and `x-peer` (the abortive-close write).
2. **A row's expected value naming a placeholder**: "the alloc dispatcher
   hands libuv the handle's own buffer, at its full length" read `s-peer` in
   its expected value. SRFI-64 evaluates a row's name and expected value
   outside its catch (`%test-comp2body`, `vendor/chez-srfi/%3a64/testing-impl.scm`
   line 642); only the tested expression, the last argument, is caught.
3. **A plain `run-until` waiting on a peer**: the cancelled-write section
   (`q-peer`) waited with plain `run-until`, whose `'once` steps block until
   an event. The listening server keeps the loop alive, so a peer that never
   arrives hangs the suite until the Makefile's timeout.
4. **A late handshake.** When the read path's wait gives up and the
   handshake completes later, the connect callback's write runs late:
   - after the EOF section's `uv-shutdown!`, it raised EPIPE inside the
     callback, and `uv-run` re-raised it from the EOF wait;
   - at teardown, the still-pending connect completed as `'ECANCELED`, the
     callback wrote on the closing stream, and `uv-loop-teardown!` re-raised
     `&uv-handle-closed`.
5. **A data wait that gives up, with the peer present.** In the backpressure
   section, a first chunk that never arrived left the reader running, and the
   top-level restart raised EALREADY.

Shapes 4 and 5 appeared only once shapes 1 to 3 were gated: each was the
next abort.

## The change

- Each top-level call on a placeholder is gated on the peer:
  `(when (uv-tcp? p) ...)`, or `(if (uv-tcp? p) ... 'never-accepted)` for a
  definition.
- A row whose expected value read a placeholder now compares inside its
  tested expression: on a0ea0ca the alloc-dispatcher row, and after the
  rebase #48's descriptor and alloc-answer rows.
- Every handshake wait whose outcome was discarded is now a named seed row:
  pending-write, cancelled-write, backpressure, reset, vectored round-trip
  and keepalive. The pending-write wait now also requires the accept, and the
  cancelled-write and pending-write waits tick.
- `handshake-cap` (4000) is the cap of every ticking wait that spans a
  loopback handshake. Each 1 ms tick spends an iteration, so a ticking cap is
  a time budget, and 64 of them were too few under load. The read path's
  first wait and the 1 MiB transfer's seed wait move from 64 to it. A seed
  row at 64 would have failed sections whose later waits used to absorb a
  late handshake (m-late below: only the seed row fails).
- The read path's EOF section runs only after the first delivery. The connect
  callback writes only on a successful connect.
- The backpressure restart is a row: "the stopped reader restarts with the
  same three callbacks".
- `tests/test-seed-gates.sps` reads `tests/test-tcp.sps` and holds shapes 1
  to 3. Rule 1: a top-level form names a placeholder only in a row's tested
  expression, inside a lambda or procedure definition, as `uv-tcp?`'s
  argument, or under a gate on that same peer. Rule 2: no plain `run-until`
  waits on a placeholder. It prints each offending form, because the runner
  prints only a failing row's name.

## The forced failures

Two plants per seed, plus one for shape 5:

- **-norec**: the accept callback's accept branch never runs,
  `(when (not err) ...)` becoming `(when (and #f (not err)) ...)`. The peer is
  never accepted or recorded, and the callback still runs.
- **-late**: the seed's wait is replaced by a procedure that answers
  `'iterations-exhausted` without running the loop, so the handshake's
  callbacks fire at whatever runs the loop next. This is what a ticking wait
  that exhausts its cap does, so it applies to ticking waits. Plain waits
  only spend iterations on events, and cannot give up early under load.
- **b-nodata**: the backpressure section's writes are withheld, so the first
  chunk never arrives and on-data never stops the read.

## RED: main (a0ea0ca)

Load ~100 to ~158. The control passed 210 rows.

| plant | exit | summary | how it ended |
|---|---|---|---|
| accepted-norec | 1 | yes | 5 named failures |
| pa-norec | **255** | no | 4 named, then `uv-read-start!` `not-a-uv-stream` |
| pending-norec | 0 | yes | 210 passes: nothing read `pending-peer` |
| q-norec | **124** | no | hung in the plain wait, killed at 240 s |
| graise-norec | 0 | yes | 210 passes: nothing reads `graise-peer` |
| s-norec | **255** | no | 5 named, then the observed `stream-read-buf` exception |
| m-norec | **255** | no | m's 4 named, then **b's handshake missed its cap under load**: b's 2 rows, then `uv-read-start!` `not-a-uv-stream` at b's restart |
| b-norec | **255** | no | 2 named, then the restart: `not-a-uv-stream` |
| x-norec | **255** | no | no row ran: the write raised `not-a-uv-stream` first |
| wv-norec | 1 | yes | the seed row |
| rt-norec | 1 | yes | the round trip's row |
| ka-norec | 0 | yes | `ka-peer` was read only by a discarded wait |
| pa-late | **255** | no | 5 named, then `not-a-uv-stream` |
| s-late | **255** | no | as s-norec |
| m-late | 1 | yes | the seed row only: m's transfer wait absorbed the late handshake |
| b-late | 0 | yes | the first-chunk wait absorbed the late handshake |
| x-late | **255** | no | the write: `not-a-uv-stream` |
| wv-late | **255** | no | **x's handshake missed its cap under load** before wv ran: `uv-write!` `not-a-uv-stream` |
| rt-late | 1 | yes | x's two ECONNRESET rows (the load flake below); rt absorbed the late handshake |
| ka-late | 0 | yes | |

Ten of the twenty plants cost the summary: nine aborted with exit 255 and
one hung. Two of the aborts were not the plant's. The backpressure and reset
sections, which waited 64 ticks for their handshakes, missed them during the
loopback floods and died exactly as the reported run did.

`tests/test-seed-gates.sps` against main's file fails both scan rows by
name. It prints 16 exposed uses in 14 forms for rule 1 (pa 1, s 13, b 1,
x 1), matching the audit, and the cancelled-write wait for rule 2.

## The aborts found on the way to GREEN

Each step re-ran its plants before the next change:

| tree | plant | result |
|---|---|---|
| placeholder gates, alloc row, seed rows | s-norec | exit 1, 20 named, summary |
| the same | s-late | **exit 255**: `Exception in uv-write!: broken pipe` (shape 4, from the EOF wait) |
| + the EOF section gated on the first delivery | s-late | **exit 255**: `&uv-callback-error` with `&uv-handle-closed: tcp`, from teardown (shape 4) |
| + the connect callback writes only on success | s-late, s-norec | exit 1, 21 named each, summary |
| the restart gated on `(uv-tcp? b-peer)` | none (unplanted, at load) | **exit 255**: `Exception in uv-read-start!: connection already in progress` (shape 5) |
| the same | b-nodata | **exit 255**: the same exception, deterministically |
| the restart as a row | b-nodata | exit 1, 4 named, summary |

## GREEN: this branch, on a0ea0ca

Load ~7 to ~38. Two control runs bracket the sweep: 217 passes each.

| plant | exit | summary | named failures |
|---|---|---|---|
| accepted-norec | 1 | yes | 5: the accept rows and the failed-accept rows |
| pa-norec | 1 | yes | 5: the seed row, three address rows, "both writes arrive, A then B" |
| pending-norec | 1 | yes | the seed row |
| q-norec | 1 | yes | the seed row |
| graise-norec | 0 | yes | none: `graise-peer` is still read by nothing (below) |
| s-norec | 1 | yes | 21, from "the peer's on-data callback delivered the client's write" on |
| m-norec | 1 | yes | 4: the seed row and the transfer's three |
| b-norec | 1 | yes | 5: the seed row, the first chunk, the idle reader, the restart, the resume |
| x-norec | 1 | yes | 4: the seed row and the three reset rows |
| wv-norec | 1 | yes | the seed row |
| rt-norec | 1 | yes | the seed row and the round trip |
| ka-norec | 1 | yes | the seed row |
| pa-late | 1 | yes | 6: the seed row, the four address rows, "both writes arrive, A then B" |
| s-late | 1 | yes | 21, as s-norec |
| m-late, b-late, wv-late, rt-late, ka-late, pending-late, q-late | 1 | yes | each its own seed row only |
| x-late | 1 | yes | 4: the seed row and the three reset rows |
| b-nodata | 1 | yes | 4: the first chunk, the idle reader, the restart, the resume |

Every failure in this sweep belongs to the planted section. The earlier
green sweep, at load ~30 to ~100 and inside the flood window, also passed
every plant this way. Its spontaneous failures were the restart abort that
shape 5 records, and named failures in other sections' cap-64 EOF and reset
waits.

**Stress.** Four rounds ran 8 copies of main's suite and 8 of this branch's
at once, at load ~32 to ~50. Neither side aborted or hung. The only failures
were the reset section's two ECONNRESET rows: 5 of 32 runs on main, 6 of 32
here.

## Mutations: tests/test-seed-gates.sps

The control passes 6 rows. Each mutation exited 1, failing the rows named:

| | mutation | fails, by name |
|---|---|---|
| S1 | a placeholder is anything but `'never-accepted` | the scan finds every placeholder peer |
| S2 | the reader stops after 100 forms | the scan finds every placeholder peer |
| S3 | lambdas are walked | rule 1's cases; the file row, with every accept callback |
| S4 | procedure definitions are walked | rule 1's cases; the file row, with `b-on-data` |
| S5 | a definition's name counts as a use | rule 1's cases; the file row, with all 12 definitions |
| S6 | a row's tested expression is walked | rule 1's cases; the file row, with 17 findings |
| S7 | rows are skipped entirely | rule 1's cases |
| S8 | a bare `(uv-tcp? p)` counts as a use | rule 1's cases |
| S9 | a `when` gate is ignored | rule 1's cases; the findings row; the file row, with every gate |
| S10 | a `when` gate on one peer gates them all | rule 1's cases |
| S11 | an `if` gate covers its else branch too | rule 1's cases |
| S12 | an `if` gate is ignored | rule 1's cases; the file row, with `s-buffer-before-cycles` |
| S13 | quoted data is walked | rule 1's cases |
| S14 | rule 2 never fires | rule 2's cases |
| S15 | rule 2 flags `run-until/ticking` too | rule 2's cases; the file row, with the nine handshake waits whose predicates name a peer |
| S16 | rule 2 counts a quoted name | rule 2's cases |
| S17 | rule 2 does not descend into forms | rule 2's cases |
| S18 | findings are dropped | the findings row |

Regressions planted in `tests/test-tcp.sps`, each caught by a file row that
names the form:

| | regression | fails, by name |
|---|---|---|
| T1 | the `pa-peer` gate removed | rule 1's file row: `(pa-peer begin (uv-read-start! pa-peer ...))` |
| T2 | the 50-cycle loop's gate removed | rule 1's file row, twice (both calls) |
| T3 | the cancelled-write seed back to plain `run-until` | rule 2's file row |
| T4 | the `x-peer` gate removed | rule 1's file row |
| T5 | a row's expected value reads `s-peer` | rule 1's file row |
| T6 | main's file | both file rows, with the 16 + 1 findings above |

**Purity.** `check-purity` poisons `CHEZ_LIBUV_SHIM`. With the poison, the
suite passes; with `(only (libuv loop) make-uv-loop)` imported and referenced,
it dies with `&uv-shim-unavailable`, and the same edit passes without the
poison. An import alone proves nothing here: Chez runs a library's body only
for a program that references one of its variables.

## Held only by forcing a seed to fail

Three gates depend on the order of runtime events, which reading the source
cannot show, so `make test` does not hold them. The forced failures above
did, and their logs are the evidence:

- the EOF section's gate on the first delivery (s-late: EPIPE without it);
- the connect callback's `(when (not err) ...)` (s-late: teardown's
  `&uv-handle-closed` without it);
- the restart as a row (b-nodata: EALREADY as plumbing).

Rule 2 also holds the cancelled-write wait's tick, which q-norec held first
(a hang on main).

## Not covered

- **`graise-peer` is still read by nothing.** The raising section has no
  handshake wait: its row's own `uv-run` ends on the deliberate raise, which
  needs only the connect. A peer never accepted changes no outcome, so
  graise-norec stays green, correctly.
- **Rows downstream of a gate can pass vacuously under a failed seed.** "a
  read callback with nread = 0 delivers nothing" and "...and reaches neither
  on-data nor on-eof" see nothing delivered because nothing was called. The
  section's own rows fail by name first, so the suite is red regardless.
- **Load flakes that now fail by name, not fixed here.** The reset section's
  abortive close sometimes sends FIN instead of RST, because the server's
  bytes have not reached the client when it closes: 5 or 6 of 32 runs at load
  ~35, on main and here alike. PR #50, open as this lands, makes the close
  wait until those bytes are queued; the two PRs merge without conflict. The
  read path's and the transfer's EOF waits, at 64 ticks, failed by name at
  heavier load.
- **Other suites start peers as placeholders too:** `test-stream` (`#f`),
  `test-flow` (`'not-accepted`), `test-facade` and `test-lifecycle`
  (`'never-accepted`), `test-callback-alloc` (`#f`). They were not audited,
  and the scan reads `test-tcp.sps` only.

## Rebased onto #48 (309c376)

#48 landed first. It replaced the read path's alloc-dispatcher rows with rows
that call the shim's alloc callback, and added `tests/test-source-rules.sps`
to `PURE_TESTS`. The rebase took #48's rows and keeps both pure suites.

On the rebased file, the scan's rule 1 named five of #48's forms, six uses.
They are the five it named against #48's branch before it merged:

- the top-level `uv-read-start!` and `uv-read-stop!` around "uv-read-start!
  hands libuv the shim's own alloc callback";
- `(define s-alloc-answer …)`;
- the expected values of "a stream's data points at its descriptor…" and
  "libuv's alloc callback answers the stream's own read buffer…" (two uses).

The two calls and the definition are gated. The two rows compare inside
their tested expressions, and expect `'at-its-descriptor` and `'own-buffer`.

#48's row "a read delivered to a stream with no read buffer is refused by
name" runs `(uv-run sl 'nowait)`. After a seed wait that gave up, that is the
read path's first loop run, so a late handshake's callbacks fire there.
Neither raises: the accept callback records the peer before starting its
read, and the connect callback writes on a client the skipped EOF section
never shut. s-late below shows it.

Re-run on the rebased tree, at load ~15 to ~50:

- **Forced failures:** every plant exits 1 with the summary and names its own
  section, except graise-norec (exit 0, as before). s-norec and s-late name
  27 rows each: the 21 above and #48's six rows that read `s-peer`. The two
  controls pass 230 rows each: main's 223, the six seed rows and the restart.
- **The scanner's sweep:** 24 of 24 as predicted, plus the control. T6
  against main's file now finds 19 exposed uses and the cancelled-write
  wait: the 13 that remain from a0ea0ca, and #48's six.

## Gates

On macOS, on the rebased tree:

- `make test`: 22 suites, `ALL SUITES PASSED` (`test-tcp` 230,
  `test-seed-gates` 6, `test-source-rules` 8);
- `make check-purity`: the five pure suites hold;
- `make check-help`: silent;
- `make test-memory`: the ASan arm, 22 suites passed.

The same gates passed over 21 suites on a0ea0ca, before the rebase
(`test-tcp` 217).

On Linux, `make test-memory-docker` ran from a `--no-hardlinks` clone of the
rebased branch at 4a6e367; the commit after it adds only this log's rebase
notes. It exited 0 in 9:04:

- `check-memory-gate` printed `MEMORY GATE CAN FAIL`.
- Each of the 22 suites' own processes had 0 errors and 0 bytes definitely
  lost. That includes `test-tcp` (230 passes), `test-seed-gates` (6) and
  `test-source-rules` (8).
- test-process's forked children show their documented 131 and 117 bytes
  (ADR-0003).

Before the rebase, `make test-memory-docker` ran from a `--no-hardlinks`
clone of 143de89, which differs from the a0ea0ca branch only by one AGENTS.md
sentence and one comment in the new suite. It exited 0 in 3:46: Valgrind 3.19
in the `chez-libuv-valgrind:10.4.1` image, vendored libuv 1.52.1.

- `check-memory-gate` printed `MEMORY GATE CAN FAIL`.
- Every suite's own process had 0 errors and 0 bytes definitely lost. That
  includes `test-tcp`, with 217 passes and its reuseport row `bound`, and
  `test-seed-gates`, with 6.
- test-process's forked children show their documented 131 and 117 bytes
  (ADR-0003).
