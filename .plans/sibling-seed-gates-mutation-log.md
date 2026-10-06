# A failed loopback seed fails the sibling suites by name: mutation log

Evidence for `test/sibling-seed-gates`. The work began on PR #52's tree
(1e68f74 and 20a39b5, rebased onto 309c376) and was rebased onto main at
eb5b719 once #52 merged, after #50, #54 and #53; "After #52 and #53
landed" covers what that changed. The change is test-only:
`tests/test-{stream,flow,lifecycle,process,constructors}.sps`,
`tests/test-seed-gates.sps` and one AGENTS.md paragraph. Its test-facade fix landed first, byte for byte,
with #57. test-callback-alloc and test-echo needed no change.

Every plant and mutation ran in a `--no-hardlinks` clone outside the repo,
with its own build. Each was an exact text replacement that aborts unless
its target occurs exactly once, every plant was validated before any ran,
and the clone's files were restored and checked after each run. A suite ran
as `make test` runs it, under `timeout 300` (`SUITE_TIMEOUT`), except where a
row says otherwise. Platform: macOS arm64 26.6.2, Chez 10.4.1 (`tarm64osx`),
libuv 1.52.1 from pkg-config, the dev build.

The machine was shared. Other sessions ran 8-process loopback floods
(1-byte `TCP_NODELAY` writes) at 07:09–07:10, 07:15–07:22, 07:28–07:31 and
07:37–07:49 local, and Valgrind containers. The RED sweep ran 07:17–07:28
at load ~170 to ~408, its first 21 runs inside a flood. The GREEN seed
plants ran 07:35–07:37 at load 8 to 18. The gate removals from G5 on ran in
the 07:37 flood, and the follow-up batch ran after it, at load ~25 to ~33.

---

## The audit

PR #52 found five shapes in `tests/test-tcp.sps` by forcing each loopback
seed to fail. These suites were not audited then:

| suite | seed | placeholder | what a failed seed reached |
|---|---|---|---|
| test-stream | the shrink sweep's peer | `s-peer`, `#f` | none of the five shapes; separately, the #49 review's M8 (below) |
| test-stream | #53's engine sweeps, after the rebase | `sw-accepted`, `#f` | shape 3: every sweep re-waited a failed handshake up to fuel 400, a hang; a reuse run without its connection could pass |
| test-flow | cross-stream isolation | the `accepted` list, read as `(vector-ref peers 0)` | shape 1: three top-level uses of reader 0 |
| test-flow | write-queue congestion | `cpeer`, `'not-accepted` | shape 1: `uv-recv-buffer-size!` and `uv-read-start!` |
| test-flow | the idle stream | `cidle-peer`, `'not-accepted` | none: read only by the seed's wait |
| test-facade | the tcp chain | `f-accepted`, `'never-accepted` | shape 4: the connect callback at teardown |
| test-facade | resolve → connect | `c-accepted`, `'never-accepted` | none |
| test-lifecycle | row 10, request blocks | `w-peer`, `'never-accepted` | none: read by nothing |
| test-lifecycle | row 11, 100 connects | the `accepts` count | shape 3: a plain `run-until` on the accept, a hang |
| test-callback-alloc | direct delivery, read | `r-peer`, `rd-peer`, `#f` | none: #48 gated both |
| test-callback-alloc | the write rows | the `w-peers` list | none |
| test-process | inherit-stream | `accepted`, `'not-yet`, in a `with-loop` body | shape 1: the spawn and the close |
| test-echo | the eight clients | the `peers` list, its accept guarded | none |
| test-constructors | #59's accept fixture, after the rebase | a pending connection, `accept-prepare` | shape 3: every sweep re-waited a failed handshake up to fuel 400, a hang |

test-process and test-echo were not on the task's list. test-process's
placeholder sits in a lambda handed to `with-loop`, which runs at once, so a
search for top-level placeholders missed it, and so did #52's rule 1, which
skips lambdas.

No suite had shape 2 (a row's expected value reading a placeholder) or shape
5 (a data wait that gives up with the peer present and leaves state that the
next call trips on). No suite restarts a reader at top level. Two no-data
plants below confirm that shape 5's failures stay named.

## The forced failures

Two plants per seed, as in #52:

- **-norec**: the accept branch never runs. `(when (not err) ...)` becomes
  `(when (and #f (not err)) ...)`. A callback with no such branch
  (test-stream's `s-peer`, test-callback-alloc's three) has its body wrapped
  in `(when #f ...)`. The callback still runs and accepts nothing.
- **-late**: the seed's wait answers `'iterations-exhausted` without running
  the loop, so the handshake's callbacks fire at whatever runs it next. In
  test-facade's hand-rolled drains, the drain's `(uv-run ... 'once)` becomes
  `#f`. In test-lifecycle's plain waits, the wait is replaced the same way.

And these:

- **stream-m8**: the #49 review's M8, in `src/`: `try-copy-in!` answers `#t`
  after copying, so every write and every spawn's copy raises
  `span-out-of-range`.
- **proc-enoent**: test-stream's spawn asks for `/nonexistent/sh`.
- **f-midway**: test-facade's drain stops as soon as the connect callback
  has run (cap 4000).
- **r11-lastlate**: only row 11's hundredth wait gives up.
- **iso-nodata**, **is-nodata**: shape 5. Reader 0's trigger write is
  withheld; the inherit-stream child writes nothing.

## RED: #52 on 309c376

| plant | exit | summary | how it ended |
|---|---|---|---|
| controls (6 suites) | 0 | yes | stream 25, flow 23, facade 70, lifecycle 68, callback-alloc 33, process 113 |
| s-norec | 1 | yes | 3 named: the seed row and two sweep rows |
| s-late | 1 | yes | the seed row |
| stream-m8 | **255** | no | `uv-write!` `span-out-of-range`, from the top-level unconnected-pipe write |
| iso-norec, iso-late | **255** | no | the seed row, then `vector-ref`: 0 is not a valid index for #() |
| c-norec, c-late | **255** | no | the seed row, then `uv-recv-buffer-size!` `not-a-uv-handle` |
| cidle-norec | 1 | yes | the seed row |
| f-norec, f-late | **255** | no | 7 named, then `&uv-callback-error` with `&uv-handle-closed: tcp`, from teardown |
| fc-norec, fc-late | 1 | yes | the resolve → connect row |
| w-norec | 0 | yes | none: `w-peer` is read by nothing |
| w-late | 1 | yes | "the connect request's block is freed when the connect completes" |
| r11-norec | **124** | no | hung in the plain wait, killed at 300 s |
| r11-late | 1 | yes | "every one of the 100 connections was accepted" |
| r-, rd-, wp- (6 plants) | 1 | yes | each seed row and the rows that need its peer |
| is-norec, is-late | **255** | no | `uv-spawn!` `stdio-spec-unknown`: the placeholder handed to `inherit-stream` |

Nine of the 23 seed plants cost the summary: eight aborted with exit 255
and one hung. stream-m8 aborted too. f-norec aborted as f-late did: at load
~250, the 32-step drain gave up before the connect completed. The test-facade session saw the same abort on
main the same morning, unplanted.

## The change

- **test-flow.** Reader 0 is named `closing-peer`, `'not-accepted` when the
  seed accepted no reader, beside `closing-col`, an empty collector then.
  The read stop and restart are gated on `(uv-tcp? closing-peer)`.
  `cpeer`'s receive-buffer shrink and read start are gated on the peer.
- **test-facade.** The connect callback goes on to nodelay, write and
  shutdown only from a successful connect. #57, which raised the facade's
  drain caps, carried the same hunk and landed first, so it is no longer in
  this branch's diff.
- **test-lifecycle.** Row 11's wait ticks, with a cap of 4000. The
  iterations stop at the first whose wait ran out, and a connect counts only
  once its callback came.
- **test-process.** The inherit-stream wait is a named seed row, the spawn
  and the close of `accepted` are gated on the peer, and the close of the
  process on `(uv-process? proc)`.
- **test-stream.** The unconnected-pipe write keeps any other raise as
  its evidence. The spawn for the refuses-process rows does the same, and
  those rows require a process first. #53's engine sweeps, which arrived
  with the rebase, stop at a failed connection (see the last section).
- **tests/test-seed-gates.sps** reads all nine suites that accept a
  loopback peer, and a row holds that list. See its section below.
- **test-constructors** (#59, after the rebase): its sweeps stop at a failed
  fixture. See "After #59 landed".

## GREEN

Seed plants at load 8 to 18, then the follow-up batch at ~25 to ~33.

| plant | exit | summary | named failures |
|---|---|---|---|
| controls | 0 | yes | stream 25, flow 23, facade 70, lifecycle 68, callback-alloc 33, process 114 |
| s-norec | 1 | yes | 3, as RED |
| s-late | 1 | yes | the seed row |
| stream-m8 | 1 | yes | 9: the unconnected write, the two refusal rows, the sweep's reach row, both bulk rows, the tcp canary, both refuses-process rows |
| proc-enoent | 1 | yes | both refuses-process rows |
| iso-norec, iso-late | 1 | yes | 5: the seed, the gate, the trigger write, both survivor rows |
| iso-nodata | 1 | yes | 2: the gate and the trigger write |
| c-norec, cidle-norec, c-late | 1 | yes | the seed row |
| f-norec | 1 | yes | 3: the peer, its read, its read stop |
| f-late | 1 | yes | 6 or 7: the whole chain; the peer-address row passes when the kernel finished the handshake first |
| f-midway | 1 | yes | 3, as f-norec |
| fc-norec, fc-late | 1 | yes | the resolve → connect row |
| w-norec | 0 | yes | none, as RED |
| w-late | 1 | yes | as RED |
| r11-norec | 1 | yes | 2: the connects and accepts rows, after one cap, in 5.5 s |
| r11-late | 1 | yes | the same 2 |
| r11-lastlate | 1 | yes | the same 2 |
| r-, rd-, wp- (6 plants) | 1 | yes | as RED |
| is-norec | 1 | yes | 5: the seed, the bytes, their content, the exit, the EOF |
| is-late | 1 | yes | 4: the EOF row passes once the late accept closes |
| is-nodata | 1 | yes | 2: the bytes and their content |

Every failure belongs to the planted section.

## Each new gate, removed

Each removal ran under the plant that needs it, and each exception names the
verb its gate guards:

| | removed | plant | result |
|---|---|---|---|
| G1 | the `closing-peer` gate | iso-norec | **255**, `uv-read-stop!` `not-a-uv-stream` |
| G2 | `closing-peer`'s default | iso-norec | **255**, `vector-ref` |
| G3 | `closing-col`'s default | iso-norec | **255**, `vector-ref` |
| G4 | `cpeer`'s buffer gate | c-norec | **255**, `uv-recv-buffer-size!` `not-a-uv-handle` |
| G5 | `cpeer`'s read gate | c-norec | **255**, `uv-read-start!` `not-a-uv-stream` |
| G6 | the facade's connect gate | f-late | **255**, `&uv-handle-closed: tcp` from teardown (twice) |
| G8 | row 11's tick, back to plain `run-until` (cap 64) | r11-norec | **124** at 120 s |
| G9 | row 11's stop at the first failed wait | r11-norec | **124** at 120 s: each of 100 iterations spends its 4000-tick cap |
| G10 | the connect count's `done` | r11-lastlate | the connects row passes. Once the suite went fully green (exit 0, 68 passes); once the accepts row still caught it. With `done`, the connects row failed in both runs |
| G11 | the spawn gate | is-norec | **255**, `uv-spawn!` `stdio-spec-unknown` |
| G12 | the close gate on `accepted` | is-norec | **255**, `uv-close!` `not-a-uv-handle`, before the EOF row |
| G13 | the close gate on `proc` | is-norec | **255**, `uv-close!` `not-a-uv-handle`, after the EOF row |
| G14 | the unconnected write's catch-all | stream-m8 | **255**, `uv-write!` `span-out-of-range` |
| G15 | the spawn's catch-all | proc-enoent | **255**, `uv-spawn!`: no such file or directory |
| G16 | the rows' process requirement | proc-enoent | exit 0, 25 passes: anything that is not a stream is refused as `'not-a-uv-stream`, a raise record included |

## Decided against, by measurement

- **An open check before the facade's shutdown.** It was planned against a
  finished write whose callback teardown would deliver while the client
  closes. libuv runs pending callbacks right after polling, inside the same
  `uv_run` (`src/unix/core.c`, from ee3718dd). So the 6-byte write's callback
  and its shutdown ran inside the drain's last `'once`: under f-midway both
  rows passed, on macOS (1.52.1) and on Debian's 1.44.2 in the valgrind
  image (3 of 3 runs, probed right after the drain: connect, write and
  shutdown all `#f`). No plant could deliver the write's callback at
  teardown, so the check would have been a decision no mutation can reach.
- **A dedupe in the scan's `seeded`.** Removing it changed no row: no suite
  sets the same variable twice in an accept branch. It went.

## tests/test-seed-gates.sps

It now reads every suite that accepts a loopback peer: test-tcp, test-stream,
test-flow, test-facade, test-lifecycle, test-callback-alloc, test-process,
test-echo and, since #59, test-constructors. A row holds that list to the
suites that call `uv-accept!` (see "After #59 landed"). Each suite's entry says how it spells
a peer not yet accepted (`spelt`, quoted), and names the peers no spelling
finds (`named`): `#f` starts plenty of variables that are not peers, and
`closing-peer` is taken from a list. test-callback-alloc's own `row` form
counts as a row (`rows`): it catches its measurement, its last argument.

What changed from #52's scan:

- **Plumbing** includes the body of a lambda handed to `with-loop` or
  `call-with-uv-loop`, since such a body runs at once. Rule 1 and the
  placeholders are read from it.
- **Rule 1** lets a placeholder be an argument of `eq?`: test-facade's drains
  compare `f-accepted` and `c-accepted` with their spelling at top level.
- **Rule 2** covers everything an accepted peer sets, not only the
  placeholder: each `set!` in the form of an accept callback that calls
  `uv-accept!`. That is what found row 11's `accepts`. On #52's tree it
  finds nothing new in test-tcp, whose first section's plain wait is on
  `connection-err`, set outside the accept branch.
- **A cross-check**: every variable a `(set! v (uv-accept! ...))` stores in
  must be a placeholder the scan knows. A new `#f` peer missing from its
  suite's list, or a peer with another spelling, fails it (T10, T11).
- Per suite, five rows: the placeholders found and what an accepted peer
  sets (both pinned), the cross-check, and the two rules. One synthetic
  suite pins what `scan` hands to which rule.

Against the unfixed suites the file rows named exactly the RED sweep's
static findings: `cpeer`'s two calls, row 11's wait on `accepts`, and the
spawn and close of `accepted`. The other aborts depend on runtime order,
which reading the source cannot show (below).

The control passed 49 rows before rule 3's port, 53 after it, and 60 once
test-constructors and the coverage rows were added. Each of the six new case rows first failed by
name against stubs of the new decisions. The synthetic suite, added after,
is the only row S30 to S32 fail. Each mutation exited 1 with its summary,
failing the rows named:

| | mutation | fails, by name |
|---|---|---|
| S1 | a placeholder is anything but its suite's spelling | the placeholder cases; the synthetic suite; placeholders of tcp, flow, facade, lifecycle, process, echo; unknown peers of tcp, flow, facade, lifecycle; rule 1 in tcp, facade, process, echo |
| S2 | the reader stops after 100 forms | placeholders of tcp, facade, callback-alloc; seeded of tcp, facade, lifecycle, callback-alloc; after the port, rule 3's vocabulary row |
| S3 | lambdas are walked | rule 1's cases; the synthetic suite; rule 1 in all but echo |
| S4 | procedure definitions are walked | rule 1's cases; rule 1 in tcp, stream |
| S5 | a definition's name counts as a use | rule 1's cases; the synthetic suite; rule 1 in all but echo |
| S6 | a row's tested expression is walked | rule 1's cases; the suite-row cases; the synthetic suite; rule 1 in tcp, flow, facade, callback-alloc |
| S7 | rows are skipped entirely | rule 1's cases; the suite-row cases; the synthetic suite |
| S8 | a bare `(uv-tcp? p)` counts as a use | rule 1's cases |
| S9 | a `when` gate is ignored | rule 1's cases; the findings row; rule 1 in tcp, flow, callback-alloc, process |
| S10 | a `when` gate on one peer gates them all | rule 1's cases |
| S11 | an `if` gate covers its else branch too | rule 1's cases |
| S12 | an `if` gate is ignored | rule 1's cases; rule 1 in tcp |
| S13 | quoted data is walked | rule 1's cases |
| S14 | rule 2 never fires | rule 2's cases; the synthetic suite |
| S15 | rule 2 flags `run-until/ticking` too | rule 2's cases; rule 2 in tcp, stream, flow, lifecycle, callback-alloc, process, echo |
| S16 | rule 2 counts a quoted name | rule 2's cases |
| S17 | rule 2 does not descend into forms | rule 2's cases |
| S18 | findings are dropped | the findings row; the synthetic suite |
| S19 | `eq?`'s arguments count as uses | rule 1's cases; rule 1 in facade |
| S20 | `eq?` hides its compound arguments too | rule 1's cases |
| S21 | a suite's own row forms are ignored | the suite-row cases; the synthetic suite; rule 1 in callback-alloc |
| S22 | `row` counts as a row in every suite | the suite-row cases |
| S23 | named placeholders are ignored | the placeholder cases; the synthetic suite; placeholders of stream, flow, callback-alloc, process; unknown peers of stream, callback-alloc, process |
| S24 | any `#f` definition is a placeholder | the placeholder cases; the synthetic suite; placeholders of stream, callback-alloc |
| S25 | any quoted symbol is a placeholder | the placeholder cases; placeholders of tcp, flow, facade, lifecycle, process, echo; rule 1 in tcp, facade, process, echo |
| S26 | a body that runs at once is not expanded | the plumbing cases; the synthetic suite; placeholders and unknown peers of process |
| S27 | any call with a lambda is expanded | the plumbing cases |
| S28 | `seeded` takes every `set!` of an accept callback | the seeded cases; seeded of tcp, echo; rule 2 in tcp (`connection-err`) |
| S29 | `seeded` sees top-level listens only | the seeded cases; seeded of lifecycle, process |
| S30 | rule 2 waits on placeholders only | the synthetic suite |
| S31 | rule 1 reads the raw forms, not the plumbing | the synthetic suite |
| S32 | the cross-check is dropped | the synthetic suite |
| S33 | `accept-stored` finds nothing | the accept-stored cases; the synthetic suite |
| S34 | `accept-stored` takes any `set!` whose value contains an accept | the accept-stored cases |
| S35 | placeholders are read from the raw forms | the synthetic suite; placeholders and unknown peers of process |

S30 to S32 are caught by the synthetic suite alone: on the fixed files each
rule has nothing to find, whichever list it is handed.

Regressions planted in the suites, each caught by the row for its suite,
whose printed finding names the form:

| | regression | fails, by name |
|---|---|---|
| T1 | test-flow's `closing-peer` gate removed | rule 1 in flow, twice |
| T2 | test-flow's `cpeer` buffer gate removed | rule 1 in flow |
| T3 | test-flow's `cpeer` read gate removed | rule 1 in flow |
| T4 | row 11 back to plain `run-until` | rule 2 in lifecycle: `accepts` |
| T5 | test-process's spawn gate removed | rule 1 in process |
| T6 | test-process's close gate removed | rule 1 in process |
| T7 | a test-facade row's expected value reads `f-accepted` | rule 1 in facade |
| T8 | test-callback-alloc's `r-peer` read gate removed (#48's) | rule 1 in callback-alloc |
| T9 | a top-level `(uv-read-stop! s-peer)` in test-stream | rule 1 in stream |
| T10 | a new `#f` peer in test-stream, not listed | seeded and unknown peers of stream: `s-peer2` |
| T11 | a new peer spelt `'never-accepted` in test-flow | seeded and unknown peers of flow: `dpeer` |
| T12 | a test-facade drain calls a verb on `f-accepted` | rule 1 in facade |
| T13 | test-echo's connection wait back to plain `run-until` | rule 2 in echo: `peers` |

**Purity.** The scan imports `(rnrs)` and `(srfi :64)` only, as before; its
`check-purity` run is under Gates.

## After #52 and #53 landed

#52 merged as eb5b719 during this work, after #50, #54 and #53, and this
change was rebased onto it. #52's final scan is byte for byte the one
extended here; three suites moved under it.

- **The cross-check caught #53's new peer at once.** #53 added engine
  sweeps to test-stream with a peer of their own, `sw-accepted`, an `#f`
  stored from an accept. On the rebased tree "the scan finds what an
  accepted peer sets in tests/test-stream.sps" and "every peer
  tests/test-stream.sps stores from an accept is a placeholder the scan
  knows" failed by name, printing `sw-accepted`. It is now on test-stream's
  list.
- **#53's sweeps hung on a failed seed.** Each run connects a link of its
  own (`connect-link!`, a ticking wait of 4000), which answers
  `(connect-failed)` when the handshake fails. That verdict is not
  untouched, so each of the 14 sweeps went on to the next fuel and waited
  again, up to fuel 400. sw-norec, the accept branch never running, was
  killed at 300 s: exit 124, no summary. A sweep now also stops at its first
  run whose connection failed.
- **A reuse run without its new connection could pass.** The reuse sweeps
  open a second connection after the free. When that connect failed, nothing
  could see a misdirected write, and the run could still count as
  `refused`. Such a run is now `(no-new-connection ...)`, a bad run, and it
  stops its sweep.
- **M8 no longer reaches the writes.** #53's verbs copy with
  `copy-in-unchecked!` inside their step, so M8 now raises only from the
  spawn. The unconnected write's catch-all is held instead by
  **write-refused**: `uv-write!`'s step answers `'span-out-of-range` for
  every span.
- test-callback-alloc: #53 changed 12 lines, and its six plants still fail
  by name on the rebased tree, as before.

On the final tree, at load ~170 to ~218 (another session's flood ended at
08:11):

| plant | exit | summary | named failures |
|---|---|---|---|
| control | 0 | yes | 32 |
| s-norec | 1 | yes | 3, as before |
| s-late | 1 | yes | the seed row |
| write-refused | 1 | yes | 11: the unconnected write, the refusal row, the shrink sweep's reach, the bulk row, the tcp canary, the six engine-sweep rows |
| stream-m8 | 1 | yes | both refuses-process rows |
| proc-enoent | 1 | yes | both refuses-process rows |
| sw-norec | 1 | yes | the six engine-sweep rows, in 102 s: one 4000-tick wait for each of the 14 sweeps, ~7 s each at that load |
| sw-late | 1 | yes | the same six, in 0.9 s |
| sw-reuse-fail (the reuse connect answers `#f`) | 1 | yes | both reuse rows |

And with each new decision removed:

| | removed | plant | result |
|---|---|---|---|
| G14 | the unconnected write's catch-all | write-refused | **255**, `uv-write!` `span-out-of-range` |
| G17 | the stop at a failed connection | sw-norec | **124** at 120 s |
| G18 | the `no-new-connection` verdict | sw-reuse-fail | exit 0, 32 passes: the reuse rows pass with nothing to see by |

## Rule 3, ported from #58

#58 (c6bdcf0) landed while this branch waited. It added a rule 3 to the
single-suite scan: no ticking wait in test-tcp.sps may give up sooner than
the longest delivery measured under a loopback flood. Its session and this
one agreed that the second to land would port the first, and this branch
landed second. The port brings over, verbatim from c6bdcf0:
- the rule 3 paragraph of the header;
- its six definitions: `ticking-waits`, `flooded-delivery-ticks`,
  `integer-definitions`, `budget`, `short-waits` and `first-uses`;
- its two case rows;
- its two file rows, as a test-tcp block after the per-suite loop.

The block reads test-tcp.sps into a variable of its own, and the header says
that rule 3 holds test-tcp.sps alone. Only those waits were measured under a
flood.

#58's "Mutations" table was then re-run against the merged file, at load ~3.
Every mutation failed the rows #58's log names. T1 to T7, T10 and T11 fail
both rule 3 file rows. T8 and T9 fail the findings row. X1 fails the reset
seed, the precondition and the two reset rows, with the summary printed, and
X2 the seed row alone. S1 to S11 fail as listed there. S12, the scan reading
no forms, now fails the vocabulary row alone: on c6bdcf0 it also failed the
placeholder row, because there both read one list of forms. This file's own
48 mutations still fail by name, and S2 now also fails rule 3's vocabulary
row.

## After #59 landed

#59 (a3750e5) landed while the PR was being opened. It added a suite,
`tests/test-constructors.sps`, whose `uv-accept!` sweeps prepare each run
with a loopback handshake (`accept-prepare`, a ticking wait of 4000) and
answer `(prepare-failed)` when it fails. That made this branch's claim, that
the scan reads every suite that accepts a loopback peer, false within an
hour of its being written. So the claim is now a check:
- "the scan reads exactly the suites that call uv-accept!" compares `suites`
  with every `tests/test-*.sps` that calls `uv-accept!` outside quoted data.
  The scan's own suite mentions it only in quoted case data;
- "calls? finds a call at any depth, and not in quoted data" holds the
  reader that row relies on.

The new suite had #53's shape. Its sweeps stopped only at an untouched run
or at fuel 400, so a failed handshake was waited out again at every fuel:

| plant | before | after |
|---|---|---|
| control | 17 passes | 17 passes |
| ac-norec (the listen callback records nothing) | **124** at 120 s, no summary | exit 1, summary, 7 named, in 26.7 s |
| ac-late (the fixture's wait never runs the loop) | exit 1, 7 named | exit 1, 7 named |
| G19: the new stop removed, under ac-norec | | **124** at 120 s |

A sweep now also stops at its first run whose fixture could not be made.
The scan lists test-constructors with no placeholder and nothing an
accepted peer sets: its accept callback records a pending connection, and
`uv-accept!` is the verb under test.

Mutations of the new rows, each failing by name (the control passes 60):

| | mutation | fails, by name |
|---|---|---|
| C1 | test-constructors dropped from `suites` | the coverage row |
| C2 | `suite-files` answers no files | the coverage row |
| C3 | `calls?` reads quoted data | the `calls?` cases and the coverage row: the scan's own suite now counts |
| C4 | `calls?` does not descend | the `calls?` cases and the coverage row |
| C5 | the `test-` prefix check removed, with a dangling `.#test-tcp.sps` lock file planted | the coverage row, which the lock file passes with the check in place |

On the final file the earlier sweeps all still fail by name. S2 also fails
the coverage row, and S28 also fails test-constructors' seeded row.

## Held only by forcing a seed to fail

These gates depend on runtime order or on values the scan does not follow,
so `make test` does not hold them. The removals above are their evidence:

- test-flow: `closing-peer`'s and `closing-col`'s defaults (G2, G3);
- test-facade: the connect gate (G6);
- test-lifecycle: the stop at the first failed wait (G9) and the `done`
  count (G10);
- test-process: the close of `proc` (G13);
- test-constructors: the sweeps' stop at a failed fixture (G19);
- test-stream: the engine sweeps' stop at a failed connection (G17) and the
  `no-new-connection` verdict (G18); the two catch-alls and the process
  requirement (G14 to G16), which are not seed plumbing at all.

## Not covered

- **`w-peer` is read by nothing.** Row 10 needs a connect, not an accept, so
  w-norec stays green, correctly, as #52's `graise-peer` does.
- **Rows downstream of a failed seed that pass vacuously.** Under c-norec,
  "the queue falls to zero AND every write completed once the peer reads"
  passed with no peer reading. Under iso-norec, "the closed reader received
  nothing further" compares 0 with 0. The section's seed row fails by name
  first, so the suite is red regardless.
- **libuv 1.44.0 and 1.44.1**, the README's floor, predate the post-poll
  pending loop (ee3718dd is in 1.44.2 and later). There, a drain that gives
  up in the very iteration that delivers the connect would leave the write's
  callback for teardown, where its shutdown on the closing client would
  raise. No gate here runs those versions, so this was not measured.
- **The caps.** test-facade's 32-step drains are the subject of
  `test/facade-load-proof-drains`, another session's branch, which leaves
  this change's hunk as it is. This change gives a failed seed a named
  failure; it does not make a slow handshake succeed.
- **test-echo** needed no change. Its accept is guarded and its waits tick.
  e-norec (its accept branch never runs) exits 1 with its summary: 21 named
  failures, every row that needs the connection phase. e-late (its
  connection wait never runs the loop) exits 1 with its summary: the 4
  connection-phase rows. Its later waits absorbed the late handshake.

## Gates

The full set ran five times as main moved: 546b424 on eb5b719; 9226938 on
d816e65 (#51); 02e56f6 on 652bb40 (#55 to #57), from whose diff #57's
identical test-facade hunk dropped out; 6fbd388 on c6bdcf0 (#58), with rule
3 ported; and 234b37d on a3750e5 (#59), with test-constructors' fix and the
coverage rows. The commit that carries this log differs from 234b37d only
in this section. The figures below are 546b424's. The later runs matched at
load ~3 to ~6, with the newer rows and suites added (test-addrinfo 53,
test-dns 126, test-process 125, test-tcp 234, test-constructors 17,
test-seed-gates 60; 23 suites from #59 on), and with the same Valgrind
verdict: every suite 0 errors and 0 bytes definitely lost. On 652bb40 the
test-process and test-facade plants and their gate removals (G6, G11 to
G13) were re-run too, with the same results as above.

On macOS:

- `make test`: 22 suites, `ALL SUITES PASSED` (test-seed-gates 49,
  test-stream 32, test-tcp 233, test-process 114), at load ~212;
- `make check-purity`: the five pure suites hold, test-seed-gates among them;
- `make check-help`: silent;
- `make test-memory`: the ASan arm, 22 suites passed.

On Linux: `make test-memory-docker` ran from a `--no-hardlinks` clone of
546b424 with its submodules dissociated, and exited 0 in 4:32: Valgrind 3.19
in the `chez-libuv-valgrind:10.4.1` image, vendored libuv 1.52.1.

- `check-memory-gate` printed `MEMORY GATE CAN FAIL`.
- Every suite's own process had 0 errors and 0 bytes definitely lost, with
  780 to 5,630 allocations each and the pass counts above.
- test-process's forked children show their documented 131 and 117 bytes
  (ADR-0003).
