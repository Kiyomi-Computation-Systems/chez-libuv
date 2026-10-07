# Bulk-copy rows: a helper that never got in, mutation log

Evidence for the change to `tests/test-threading-stress.sps`'s section "bulk
copies stay plain, not __collect_safe (issue #35)". Each copy row now runs
intervals until the helper thread has tried to collect inside one: at least
its old count (10 for copy-in!, 3 for copy-out), at most 100. Between
intervals the helper is parked and collects. So a copy-out interval's
64 MiB result never outlives the next park, and a new row holds that.

## The incident

`.plans/careless-pool-starvation-mutation-log.md`, "Two more rows that flake
near load 200", item 2: on 2026-10-07, macOS arm64 (8 cores) under 96 `yes >
/dev/null` hogs plus other sessions' work, at a 1-minute load of 205:

```
FAIL no collection completes while copy-out is inside its foreign call
  actual: (never-tried 0)
```

That was 1 of 279 suite runs at loads 165–227, and 0 of 170 at loads 40–214.

The row's verdict was `(list (if (> attempts-inside 0) 'tried 'never-tried)
collections-inside)`, and only `'(tried 0)` passes. `(never-tried 0)` says
the helper made no attempt wholly inside any of the three copy-out
intervals. The precondition failed, not the property: nothing collected
inside a copy, and nothing tried to.

Copy-out ran only 3 intervals because each allocates a 64 MiB result, and
`collect-trip-bytes` is raised for the section, so nothing collected those
results.

The load window below found the same failure in **copy-in's** row on main
(run 18, load 173, `(never-tried 0)` over its 10 intervals). Both rows had
it, so both get the change.

## RED: a helper that is never scheduled, on demand

A scratch copy of main's suite sleeps the helper 1 s before its first
attempt of one leg: a descheduled helper, made deterministic. The leg's
intervals end long before it wakes.

| stand-in, main's suite | runs | result |
|---|---|---|
| first copy-out attempt stalled 1 s | 3 | `FAIL no collection completes while copy-out is inside its foreign call`, `actual: (never-tried 0)`, 11 pass, every run |
| first copy-in attempt stalled 1 s | 3 | both rows `(never-tried 0)`: the helper sleeps through both legs, every run |

The first is the incident's failure, byte for byte.

## The change

- **Until tried.** `inside-verdict` takes its minimum and runs intervals
  until the helper has tried inside one, at most `max-intervals` (100). At
  the cap it answers `(never-tried c in 100 intervals)`, which fails the
  row by name with its evidence.
- **Parked between intervals.** Before each interval the main thread
  releases the helper. After it, the main thread asks for a park and waits
  for it, at most 1,000 waits of 10 ms. So each interval begins with the
  helper just woken, and the cap counts the helper's wakes that missed an
  interval, not the main thread's own work (AGENTS.md: bound a thread by
  the other's progress). A helper that never parks fails all three rows
  `(never-parked after k intervals)`.
- **A collection in each park.** The helper collects the first time it
  sees each park. The main thread is then inside `condition-wait` on the
  mutex the helper holds, so no other thread is active and the collection
  runs: a counting copy saw 22 park collections and 0 refusals in each of
  3 runs at load ~136. Each interval's result is dropped, so the park frees
  it.
- **The memory row**, "copy-out's intervals keep at most one 64 MiB result
  alive". `peak-growth` is the most `(bytes-allocated)` rose above its
  value at the first park, sampled after each interval's copy. Its only
  success value, `'bounded`, needs at least 2 intervals run and a peak of
  at least one result (`n`) but under two (`2n`). On a correct build the
  first interval alone reaches `n`: nothing collects between the first
  park and that sample.
- **The minimums stay 10 and 3.** A first draft ran copy-out 10 times too,
  since memory no longer limits it. Under load that let `__collect_safe`
  on copy-out abort Chez more often (below), so copy-out keeps its 3.

## GREEN

The same stand-ins on this change, through a counting copy that prints each
verdict, its attempts inside, its intervals and the intervals no attempt
landed in ("empty"):

| stand-in | result |
|---|---|
| first copy-out attempt stalled 1 s | 13 pass; copy-out 3 intervals, 1 empty |
| first 5 copy-out attempts stalled 1 s each | 13 pass; 6 intervals, 5 empty |
| first 15 copy-out attempts stalled 0.1 s each | 13 pass; 16 intervals, 15 empty |
| first 15 copy-in attempts stalled 0.1 s each | 13 pass, 3 of 3 runs; copy-in 16 intervals, 15 empty |
| every copy-out attempt stalled 0.1 s (never scheduled in time) | `FAIL no collection completes while copy-out is inside its foreign call`, `actual: (never-tried 0 in 100 intervals)`, in 11.9 s |

The last is the row doing its job: a helper that never gets in fails by
name, with the evidence, instead of passing or hanging.

## Under load

2026-10-07, 19:16–19:44 EDT, announced to the other chez-libuv sessions.
96 `yes > /dev/null` hogs, each under `timeout 1800`, plus other sessions'
work, which took the load to 469. Main's suite and this change's alternated
run by run in scratch copies. Loads are 1-minute averages.

| suite | runs | load | failed |
|---|---|---|---|
| main's | 83 | 88–468, median ~290 | **2**: run 18, load 173, copy-in! `(never-tried 0)`; run 41, load 334, copy-out `(never-tried 0)` |
| this change's, copy-out minimum 10 (the draft) | 58 | 98–469, median 299 | 0 |
| this change's, final | 25 | 267–352, median 287 | 0 |

The draft's probe counted copy-out's empty intervals: 14 of 52 runs had one
or two of their ten. Main's three-interval row fails only when all three
are empty, which is why it is rare. In the final shape's 23 probed runs,
copy-out never needed more than its 3 intervals.

## Mutations

Per AGENTS.md, every mutant ran in a scratch copy outside the repo
(`src/`, `tests/`, `Makefile`, `build/scheme-libs`; `config.sls` names the
worktree's built shim, which no mutant changes), from the scratch directory
with `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs`, as `make
test-threading` runs it. Every mutant runs the whole suite. The repo tree
was checked clean afterwards.

### The mutation the rows exist for: S12

`.plans/bulk-copy-mutation-log.md`'s S12, `__collect_safe` on the copy
bindings, written as `(foreign-procedure __collect_safe (shim-entry
"chez_uv_copy_in") …)` in place of `shim-procedure`.

At loads 42–49, final shape, 3 runs each:

| | mutation | result |
|---|---|---|
| S12 on main | both bindings | `FAIL … copy-in! …` `(tried 344)`–`(tried 406)` and `FAIL … copy-out …` `(tried 3)`, every run |
| S12 | both bindings | `FAIL no collection completes while copy-in! is inside its foreign call` `(tried 318)`–`(tried 375)`; `FAIL no collection completes while copy-out is inside its foreign call` `(tried 3)`; the memory row `(grew 134217792 over 3 intervals)`; every run |
| S12-in | copy-in's binding only | `FAIL … copy-in! …` only, `(tried 320)`–`(tried 355)`; 12 pass |
| S12-out | copy-out's binding only | `FAIL … copy-out …` `(tried 3)`, every run; the memory row too in 2 of 3 |

Copy-out's mutant collects once per interval. Its knock-on on the memory
row: a collection made inside a copy-out promotes that interval's live
result out of the youngest generation, and the next park's `(collect)`
does not reach it. Only a collection inside a copy can do that.

**Under load, S12 can abort Chez.** At loads 166–470 a mutant's collection
inside copy-out sometimes corrupts the heap. Then copy-out raises `invalid
memory reference`, which fails the row by name as `(raised …)`, or Chez
aborts outright with `nonrecoverable invalid memory reference` (exit 134),
before any row reports. Either way the suite fails. Runs under load, by
suite:

| suite | mutant | runs (load) | copy-out row by name | no summary |
|---|---|---|---|---|
| main's | copy-out only | 6 (300–313) | 6: `(tried 23)`–`(tried 766)`, one `(raised …)` | 0 |
| the draft, copy-out minimum 10 | copy-out only | 7 (299–406) | 4: `(tried 6)`, `(tried 284)`, two `(raised …)` | **3** |
| final, copy-out minimum 3 | copy-out only | 8 (281–286) | 7: `(tried 162)`–`(tried 2365)`, one `(raised …)` | 1 |
| main's | both | 10 (335–469) | 8; one run **passed** copy-out's row, one failed it `(never-tried 0)` without testing the binding | 0 |
| the draft | both | 14 (166–469) | 10 | **4** |

Each run with no summary that was kept ended `nonrecoverable invalid memory
reference`, exit 134. The first four were filtered to their FAIL lines and
not kept. In every run that reported, mutated copy-in failed its row by
name: `(tried 63)`–`(tried 1994)` (copy-in alone: 4 of 4 at 298–334). The
draft's longer copy-out runs gave the mutant more chances to abort Chez, so
copy-out kept its minimum of 3. Main's suite never aborted, but its three intervals let
copy-out's mutant through in 2 of 10 runs, and the copy-in row was what
failed the suite.

### This change's decisions

Final shape, 2 runs each unless noted:

| | mutation | result |
|---|---|---|
| M1 | the park does not collect | `FAIL copy-out's intervals keep at most one 64 MiB result alive`, `(grew 201953840 over 3 intervals)`, `(grew 202546832 …)` |
| M2 | each result kept alive in a list | the memory row, `(grew 201329632 over 3 intervals)`, `(grew 201353216 …)` |
| M3 | peak sampled before the copy | the memory row, `(peak-below-one-result 112)`, `(peak-below-one-result 49264)`: the seed bound |
| M4 | copy-out's minimum 1 | the memory row, `(ran 1 intervals)`: the run-length bound |
| M8 | `park-helper!` does not wait for the park | the memory row, `(grew 202868128 over 3 intervals)`, `(grew 201969792 …)` |
| M7 | the helper never acknowledges a park (1 run) | all three rows: `(never-parked after 0 intervals)` twice, `(ran 0 intervals)`; 10 pass, in 26 s (two 10 s bounds) |
| M6 | a fixed count, not until tried (1 run) | with the first 15 copy-out attempts stalled 0.1 s: `FAIL … copy-out …` `(never-tried 0 in 3 intervals)`. Unmutated, the same stand-in passes 13 |
| M5 | `'tried` without an attempt inside (1 run) | with every attempt stalled 0.1 s: passes 13, vacuously. Unmutated, the same stand-in fails `(never-tried 0 in 100 intervals)` |
| M9 | no `max-intervals` cap (1 run) | with every attempt stalled: still running at a 40 s external timeout (exit 124). Unmutated, the row fails by name in 12 s |

M5, M6 and M9 are liveness decisions. A correct build at idle passes with
or without them, so only a stand-in for a starved helper can see them. The
stand-ins are recorded here, not in the suite.

A first M4 edit put `; MUT` before the line's closing parentheses, so the
suite never compiled and printed nothing. That proved nothing, and the
edit was narrowed to the call's argument.

## Properties with no row of their own

- **The guard around the park's `(collect)`.** It matters only after the
  main thread has given up waiting for a park (10 s), when a late helper's
  collection could be refused while the main thread runs. Unguarded, that
  refusal would kill the helper and hang the final join. M7's helper never
  reaches the collect, so no mutant here exercises it. Both counters start
  at 0, so the helper's first park asks for no collection while the main
  thread is still starting up. With `parked-for` at -1 that first
  collection was refused every run, silently.
- **Release before the epoch turns odd.** `release-helper!` takes the mutex
  while the epoch is even. Taking it with the epoch odd would be harmless
  too: the helper holds that mutex only while parked, never during an
  attempt. It is a choice, not a defence.
- **The final join stays unbounded**, as on main. A helper ends at its next
  loop or park once `stop` is set, and the main thread sets it under the
  mutex with a broadcast.
- **Why S12 aborts Chez under load.** Not diagnosed. The rows' 64 MiB
  buffers are meant to keep a broken binding from crashing the suite, and
  idle they do: every S12 run here at loads under 50 failed its rows by
  name. Under load main's suite raised the same `invalid memory reference`
  from inside copy-out, but no run of it aborted (0 of 16).

## Final gate

At loads 5–50, as other sessions' work wound down, on the final file:

- `make test`: ALL SUITES PASSED.
- `make test-threading`: STRESS SUITES PASSED, 13 passes, 8 of 8 runs.
- S12 on both bindings, against the final file: all three rows by name,
  2 of 2.
- `make check-purity`: purity holds.
- `make check-help`: exit 0.
