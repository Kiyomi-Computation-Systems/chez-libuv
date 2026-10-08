# Shared list reads and one engine-sweep driver (#81), mutation log

Evidence for #81, the refactor left from #66 item 4:

- `(libuv private lists)` gains `let-fixed-list`, a fixed-length read.
  uv-spawn!'s pipe specs and uv-write*!'s `(bv start end)` spans use it.
- uv-write*! reads its segment list with `read-proper-list`, not its own
  count-then-walk.
- `tests/uv-sweep.sls` holds one engine-sweep driver (`run-capped`, `capped`,
  `sweep-fuels`), and `tests/test-sweep.sps` holds it. test-dns, test-addrinfo,
  test-address, test-native, test-tcp, test-stream and test-process now use it.

Every mutation below was made in a scratch copy of the tree outside the repo,
with the suites run there. Each was checked to fail the row it was aimed at,
by name, and then reverted. macOS arm64, Chez 10.4.1, 2026-10-07.

## let-fixed-list (tests/test-native.sps)

| Mutation | Row that failed | Actual |
|---|---|---|
| A stub that always answers its mismatch | "binds each element of a list exactly as long as its names"; "evaluates its mismatch only on a mismatch, once" | `(mismatch mismatch mismatch)`; `(mismatch 1 mismatch 2)` |
| The walk's end check dropped | "answers its mismatch for any other shape, wherever it goes wrong" | `(1 2 3)` for `(1 2 3 4)`, `(1 2 3 . 4)` and a 3-cycle; `(1 1 1)` for a 1-cycle |
| The mismatch evaluated eagerly | "evaluates its mismatch only on a mismatch, once" | `(1 1 mismatch 2)` |
| Each cdr routed through `(car (reverse (list ...)))` | "allocates nothing, where the meter sees a 64-byte allocation" | `(96 64 meter-live)` |
| Shape checked by one walk, elements read by `list-ref` (two reads) | "answers the list or its mismatch for a list another thread changes, never raising" | `(100000 13532 (0 (raised "list-ref: index 5 reaches a non-pair ...")) some-whole)` |

Two of these did not work as first written:

- **The stub passed the race row.** A read that always mismatches is counted
  as a cut on every round, and the row asked only for no bad answers. The
  row now also requires that some reads answered the whole list.
- **`(car (list (car p)))` allocated nothing.** cp0 folds it, so the suite
  passed and the mutation proved nothing. `(car (reverse (list (cdr p))))`
  survives cp0, and the allocation row fails on it.

## The ported call sites

| Mutation | Row that failed |
|---|---|
| `read-stdio-spec` back to check-then-`cadr` (#66's shape) | test-process "uv-spawn! refuses a call whose pipe spec another thread cuts, for the whole spec or the cut one, and for nothing else" (`raised "cddr: incorrect list structure"`) |
| `parse-write-segment` checking the shape, then reading with `cadr`/`caddr` | test-stream "a uv-write*! whose span another thread changes is refused by the verb, never by Chez" (`raised "caddr: incorrect list structure"`) |
| uv-write*! back on main's `read-segments` | test-stream "a uv-write*! whose segment list became another proper list during the call writes it as it was or as the change left it, never refusing it": runs 13–24 (19–24 after the verdict change below) `refused-as (uv-write*! segments-not-a-list)` |

The splice sweep's change turns the third pair's cdr into ten fresh segments
of 5 and 4 bytes. The list then holds 13 segments instead of 12, and its
bytes stay at 60. Either version therefore drains the same count, and the
bytes show which version was written.

## The driver (tests/test-sweep.sps)

| Mutation | Rows that failed |
|---|---|
| No cap | "gives a call up after resume-cap resumes"; "capped answers the call's value, gives up a call that outlasts the cap" (`finished`) |
| Change at every expiry | "makes its change once, at the first expiry" |
| Change never made | "makes its change once, at the first expiry" |
| `expired` always `#f` | "makes its change once"; "gives a call up" |
| A raise inside not raised again | "raises again, outside the engine, what the call raised" |
| `stuck?` = `pair?` | "stuck? is true of the give-up alone" (and every sweep row, whose sweeps then stop at once) |
| No stop at a run no expiry reached | "runs fuel 1 up, and stops at the first run no expiry reached"; "keeps the runs before a raise" |
| `max-fuel` ignored | "stops at its last fuel" |
| No stop at a give-up | "stops at a run given up" |
| `stop?` ignored | "stops at a run its stop predicate names" |
| No guard between runs | "keeps the runs before a raise"; "a sweep-raised verdict names what was raised" |
| Fuel from 0 | five sweep-fuels rows |
| First slice given `resume-fuel`, not FUEL | "gives the call FUEL ticks before the first expiry" |

The last row is new. The first round of global mutations below showed that
no driver row noticed a first slice that ignored FUEL.

The give-up rows use a call that spins three times the cap's ticks. That is
measured at one tick per iteration: 10,000,000 iterations expire a 100,000-tick
engine 100 times, and 30,000,000 take 25 ms. So without a cap the call
finishes, and the row fails rather than hangs.

## test-dns's uncapped resume

Its new row hands `lookup-verdict` a stand-in that spins three caps' worth of
ticks and then calls `uv-getaddrinfo!`. `lookup-verdict` was then put back on
main's resume loop, `(run next 100000)` with no cap. The row "a lookup still
running at the driver's cap is given up" failed with `(refused #t)`: the
stand-in finished, and the lookup ran with the variant's change applied.

## The ported suites against a broken driver

The issue asked for this check: break the shared driver and run every ported
suite against it.

| Driver mutation | Rows that failed |
|---|---|
| Change never made | test-sweep 1; test-dns 1; test-addrinfo 4; test-address 1; test-native 4; test-stream 3; test-process 2. Each is a sweep's reach row: "began with a refusal / saw its change / changed the list before ..." |
| First slice ignores FUEL | All of the above except test-sweep's change row, plus test-sweep's new FUEL row |
| No cap | test-sweep 2; test-dns's cap row |

In the first round, "change never made" left test-stream's splice reach row
green. That row accepted a write of either version, so it could not show
that the splice had landed. The verdict now says `written-as-changed` when
the bytes are the spliced version's, and the reach row requires it at fuel 1.

### What no suite row covers, and why

- **The cap, in every suite except test-dns.** A cap is visible only on a
  call that never ends, and a correct build has none. test-sweep holds the
  driver's cap, and test-dns's stand-in row holds that `lookup-verdict` goes
  through it. In test-addrinfo, test-address, test-native, test-stream and
  test-process (`start-run!`, `start-state-run!`), going through the driver
  is a direct call, held by nothing but the source. test-process's two
  spawn sweeps and test-native's `truncation-outcome` also resumed with no
  cap until this change; the issue did not list them. A stand-in row for
  each would mean restructuring each verdict around an injected call, as
  `lookup-verdict` now is.
- **test-tcp's `capped`.** Its row changes nothing and loops on nothing in a
  correct build, so no driver mutation fails it. test-sweep's `capped` row
  holds the procedure itself.

### Not ported

These are split or drop sweeps, not change sweeps:

- test-tcp's install and close sweeps;
- test-constructors, test-process-steps, test-async-fence, test-timer,
  test-loop and test-loop-threads.

Each stops an engine once, acts, and then resumes it once with a 10,000,000-tick
budget or drops it. Each is already capped. test-native's `count-trial`
makes up to two changes at random expiries and resumes at a chosen fuel. It
is capped at 100 resumes.
