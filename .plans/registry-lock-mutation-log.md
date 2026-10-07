# The registry shared by every loop's thread (#70): evidence and mutations

Issue #70, found reviewing #68: two loops, each run on a thread of its own,
corrupted the binding's handle registry. `docs/api.md` allows exactly that
("One thread per loop"), and ADR-0019 names a thread per core as its driver.
This log holds the reproduction, the two designs measured against each other,
the tests, and the mutations that show each test fails by name.

macOS arm64 (8 cores: 4 performance, 4 efficiency), Chez 10.4.1 threaded,
libuv 1.52.1, unless a section says otherwise. Base: main `bfd2bbe` (#72).

## What was shared

Every loop's thread reaches four pieces of process-wide state, and on main
none of them had a lock.

| State | Where | What two threads did to it |
|---|---|---|
| The handle registry, one `eqv` hashtable for every loop | `handles.sls` | Corrupted: 4 of 4 runs of the issue's probe on `5ac8469`, and 6 of 6 at 1,000 rounds a thread on `bfd2bbe` |
| The walk cell, where `handle-in-loop-queue?` collects `uv_walk`'s pointers | `handles.sls` | A walk lost its pointers to another thread's reset: 1–202 of 20,000 checks per thread on main, 186–1,262 with the registry locked and the cell still shared |
| The orphan event list | `handles.sls` | 99,377–142,629 of 200,000 events kept (29–50% lost) |
| The debug shim's allocation counters (`live_*`) | `libuv-shim.c` | `+=` lost updates: timer counts off by up to 14, blocks by up to 6, after balanced work |

The probe of the issue, `timer-race.sps`, makes and closes timers on two
threads, each with a loop of its own. On main it raised
`pointer-already-registered` (from `uv-registry-register!`), `invalid memory
reference`, or, at teardown, `registry-entry-loop: 0 is not of type
registry-entry`. Rounds a thread against failures, on `bfd2bbe`:

| Rounds a thread | Runs failed |
|---|---|
| 500 | 2 of 6 |
| 1,000 | 6 of 6 |
| 2,000 | 6 of 6 |
| 5,000 | 6 of 6 |
| 20,000 | 6 of 6 |

One thread alone made and closed 20,000 timers in 290 ms, clean.

The walk race was not seen through `uv-spawn!` at its natural width, even
with 2,000 idle handles in each loop: a failed spawn's handle is the newest,
so `uv_walk` visits it last, and the reset has to land between that visit
and the read. Two threads asking `handle-in-loop-queue?` about a loop with
one timer, 20,000 times each, show it at once (the numbers above).

## Two designs

Both were built as scratch prototypes on `bfd2bbe`, with the walk cell a
thread parameter in each:

- **L, one lock.** Every use of the registry and of the orphan list holds one
  mutex, taken and released only with interrupts disabled, the shape of the
  send fence (#33). 37 lines in, 18 out, all in `handles.sls`.
- **P, a table per loop.** Each loop record holds its own table. The seams
  find the table through the loop their thread is running: `uv-run` records
  it in a thread parameter, and each running loop links to the one it was
  entered from, so an engine suspended in one loop's callback while the
  scheduler runs another loop still finds its own. The orphan list became a
  box updated with `box-cas!`.

Both passed the new suite's races 10 of 10. Against the 25 default suites,
L passed all 25 unchanged; P failed 13, as its partial conversion left the
request paths (DNS requests have no handle, so their records would need a
loop) and the suites' registry helpers unconverted.

### Timing

Each row is the median, over 5 alternated rounds, of the threads' median
(each thread's best of 30 repetitions), in ns an operation. Each repetition
makes 2,000 timers, fires them, and closes them, on a fresh loop per
thread. "make" is a constructor (one registry add), "fire" a timer callback
(one seam lookup), "close" a close callback (a lookup and a delete).
`main` cannot run on more than one thread.

With the release shim and collections held off
(`collect-trip-bytes` 2^29), load 8–12 (the 1-minute average was gated below
12):

| Threads | Design | make | fire | close |
|---|---|---|---|---|
| 1 | main | 129 | 364 | 310 |
| 1 | L | 156 | 402 | 380 |
| 1 | P | 128 | 374 | 322 |
| 2 | L | 247 | 990 | 966 |
| 2 | P | 169 | 740 | 938 |
| 4 | L | 381 | 2,714 | 3,420 |
| 4 | P | 170 | 1,651 | 1,608 |
| 8 | L | 458 | 4,821 | 4,654 |
| 8 | P | 170 | 3,440 | 4,184 |

So the lock costs 27 ns a constructor, 38 ns a callback and 70 ns a close
(two uses) on one thread, and allocates nothing (`tests/test-callback-alloc.sps`
passed L unchanged). P is within 12 ns of main. Past one thread both designs
slow down, P too: something else shared dominates at 4 and 8 threads,
where single runs scattered widely (fire at 8 threads: L 1,024–6,888, a
spread of 6.7x; P 1,734–5,292, 3.1x). Collections were held off, not
ruled out, so they are among the candidates, with the allocator. With the debug shim
the figures were close to these at one thread (L 156/390/370, P 121/355/306,
main 125/349/302).

A loopback round trip, a 64-byte message the server echoes, 5,000 times on
each thread's own pair, median of 3 rounds of each thread's best of 5, in µs:

| Threads | main | L | P |
|---|---|---|---|
| 1 | 76.3 | 75.7 | 76.9 |
| 2 | | 91.2 | 92.7 |
| 4 | | 120.1 | 120.1 |
| 8 | | 231.3 | 216.3 |

Ranges overlapped at every thread count (8 threads: L 222.6–232.8, P
213.4–231.5). Each loop thread spends most of a round trip waiting on the
kernel, so 8 registry uses in about 120 µs never queue for the lock.

The 6:00–6:40 runs of the first prototypes are not in these tables: another
session ran 96 CPU hogs then (load 150–215), and single runs of the same
work took 92–2,798 ms.

### The choice

The user chose L, on these trade-offs (ADR-0019, decision 4's amendment):

- P removes the lock and its contention, but its seams depend on a new
  invariant, that every callback of a loop fires while its thread runs that
  loop, which `uv-run` would maintain by hand across engine suspensions (it
  has no `dynamic-wind`, #45). It also leaves a constructor called from the
  wrong thread able to corrupt its loop's table, needs a shared list of live
  loops for process-wide counts, and changes six libraries, the request
  records and the suites' helpers.
- L keeps every registry signature, and its discipline can be read off the
  source (rule 6 below). If contention ever shows, several tables chosen by
  pointer, each with its own lock, keep its lookups independent of the
  running loop.

## The fix

- `handles.sls`: `registry-lock` and `with-registry-lock`
  (disable-interrupts, mutex-acquire, body, mutex-release,
  enable-interrupts). Every use of `registry` and `orphan-events` sits inside
  it: `registry-add!`, `registry-remove!`, `registry-deregister!` (the
  lookup and the delete as one body, the raise after), `registry-ref`,
  `registry-loop-of`, `registry-count`, `registry-entries` (copied out for
  the teardown's snapshot and its DNS cancellations, which call libuv after
  the lock is released), the seams' lookup, `record-orphan-callback!` and
  `orphan-callback-events`.
- The walk cell is `(make-thread-parameter '())`.
- `one-step`'s comment allows a step body to wait for the registry's lock,
  whose holder waits on nothing.
- `libuv-shim.c`: the debug counters go through `count_add` and
  `count_read`, `__atomic_fetch_add` and `__atomic_load_n` in relaxed order,
  under `-std=c99` (GCC and Clang builtins; any other compiler stops at an
  `#error` when the counters are compiled in).
- `registry-lock` is exported for the tests' probe.

## Tests

As first pushed. The review changed several of these (the review, below):
the overlap's bound, the spawn race, the sweeps, the counter race, and
most of rule 6.

`tests/test-loop-threads.sps` (new, default gate):

- **The lock's probe:** one long-lived thread tries the lock without
  blocking. A row requires it to see the lock held while the suite holds
  it, and free after.
- **Lock sweeps:** `registry-count`, `record-orphan-callback!`, a `uv-run`
  that delivers a timer's callback, and a `uv-run` that delivers a close,
  each in an engine at fuel 1, 2, ... until a run finishes with no expiry.
  At each expiry the probe must find the lock free. A precondition row
  requires each sweep to have expired at least once.
- **Races,** each 3 times on fresh threads and loops, each thread on a loop
  of its own:
  - timers made and closed (2,000 rounds);
  - `handle-in-loop-queue?` asked about the loop's one timer (20,000);
  - a missing file spawned (40), each spawn to fail with ENOENT alone;
  - orphan events recorded (20,000), every one kept;
  - a timer counted made and freed through the debug shim's counters
    (100,000), every update kept.
- **Overlap:** each thread counts how often the other's progress counter
  moved during its own run, and a precondition row per race requires both
  to have seen it move. Under the CPU hogs (load 173) one timer race ran its
  two threads one after the other, so a thread past its rounds carries on,
  up to 20 times them, until each has seen the other move or the other has
  finished.
- **Balance:** every debug counter and the registry's size back where they
  started.

The races are skipped under `CHEZ_LIBUV_UNDER_VALGRIND`, which runs one
thread at a time; the sweeps need no race and run there too.

`tests/test-source-rules.sps` gains rule 6:

- every variable a library in `src/` defines at its top level and then sets
  (anywhere in the library), or binds to a call of a maker in
  `mutable-makers`, is listed in `shared-state` with how threads share it:
  `library-init`, `init-lock`, `registry-lock`, `thread-local` or `lock`. A
  new one fails until it is listed, and a listed one that is gone fails too;
- a variable listed `thread-local` is a thread parameter, and a `lock` a
  mutex, each made once and never set;
- the variables listed `registry-lock` in `handles.sls` (pinned: `registry`,
  `orphan-events`) are used only inside `with-registry-lock`, read form by
  form, so the keyword quoted among a call's arguments does not count.

The scan found 19 variables on the fix: 6 in `constants.sls` (set by
`constants-init!` under the init lock), 5 in `native.sls`, 8 in
`handles.sls`. Seeded rows hold each checker: a set! inside another set!'s
value, a quoted set!, a local set!, a quoted use, a use in a macro, and the
keyword as a quoted argument.

### Red

- Main plus only an unused `registry-lock` exported (`red-hook`, main's own
  shim): 8, 8 and 5 rows failed in 3 runs, every race, the orphan row, the
  counters and the registry's balance; the precondition rows too where a
  thread raised before the other moved. The lock rows pass there: nothing
  takes the lock. Races run one after another in one process, so a later
  race's row can fail on what an earlier race corrupted: the spawn race
  alone passed under every mutant (the review, below).
- Rule 6 against main's `handles.sls`: 3 rows failed by name. `registry-lock`
  listed but gone; `registry-lock` and the walk cell not made as listed; and
  the lock-use row named all 11 unlocked definitions, `seam-lambda` among
  them.

## Mutations

Each mutation is an exact text replacement in a scratch copy of `src/` and
`tests/` (a shim mutation builds the copy's own shim with the Makefile's
compile line); `mutate70.py` and `mutations70.py` in the session scratchpad.
`tests/test-loop-threads.sps` ran 5 times per mutant (its races are
probabilistic), `tests/test-source-rules.sps` once. Each cell counts the runs
in which the row failed by name.

| ID | Mutation | Failed by name | Runs |
|---|---|---|---|
| K1 | `registry-add!` unlocked | rule 6's lock row; the timer race | 1/1; 3/5 (one run died of SIGILL, exit -4) |
| K2 | `registry-remove!` unlocked | rule 6's lock row | 1/1 (races 0/5) |
| K3 | `registry-deregister!` unlocked | rule 6's lock row; the timer race | 1/1; 1/5 (four runs hung, killed at 90 s) |
| K4 | `registry-ref` unlocked | rule 6's lock row | 1/1 (races 0/5) |
| K5 | `registry-loop-of` unlocked | rule 6's lock row | 1/1 (races 0/5) |
| K6 | `registry-count` unlocked | rule 6's lock row | 1/1 (races 0/5) |
| K7 | `registry-entries` unlocked (a teardown's snapshot, its DNS cancellations) | rule 6's lock row | 1/1 (races 0/5) |
| K8 | the seams' lookup unlocked | rule 6's lock row | 1/1 (races 0/5) |
| K9 | `record-orphan-callback!` unlocked | rule 6's lock row; the orphan race | 1/1; 5/5 |
| K10 | `orphan-callback-events` unlocked | rule 6's lock row | 1/1 (races 0/5) |
| K11 | `with-registry-lock` takes no lock | the timer race; the orphan race | 4/5 each (one run died of SIGILL) |
| K12 | `with-registry-lock` takes the lock with interrupts enabled | the lock sweep row | 5/5 |
| K13 | the walk cell one variable for every thread again | rule 6's thread-local row; the walk race | 1/1; 5/5 |
| K14 | the shim's counters updated with plain `+=` again | the counter race; the balance row | 5/5; 5/5 (the balance row alone, before the counter race was added: 4/5) |
| H1 | a race's threads run one after the other | the four precondition rows (all there were: H1–H3 ran before the counter race was added) | 5/5 |
| H2 | the overlap witness never counts a move | the precondition rows | 5/5 |
| H3 | the lock's probe always answers free | the probe row | 5/5 |

Every mutation failed a row by name. What the table shows:

- **The races catch an unlocked writer on the paths they run, and no unlocked
  reader.** Removing the lock from a reader (K4–K8, K10) or from
  `registry-remove!` (K2), which only failure paths call, passed all 25 race
  runs. Rule 6 is what holds those: it reads every use off the source, so
  each fails on every run.
- **K11 is rule 6's blind spot by design:** the uses stay inside the form, so
  only the races see a lock that does not lock, in 4 of 5 runs.
- **A broken build can hang the suite.** In K3 a corrupted table made a
  lookup loop for good inside the lock, with interrupts disabled, where
  nothing can stop it: four runs hung. `make test` reports such a suite as
  `HUNG` at 300 s, and runs `tests/test-source-rules.sps` too, which fails
  by name. K1 and K11 each died of SIGILL once: a corrupted table is
  undefined behaviour, and a race row can only report it when the process
  survives.
- **The lock sweeps' expiries**, before a run finished: `registry-count` 1,
  `record-orphan-callback!` 2, a timer's firing 36, a close 21. K12 shows
  only where a table operation has a trap check inside it; the firing and
  close sweeps have them.

Not mutated, as equivalent:

- `registry-deregister!`'s lookup and delete split into two bodies under the
  lock: a pointer's entry is added and removed by its own loop's thread, so
  nothing can come between them.
- `with-registry-lock` taking the lock before disabling interrupts, or
  enabling them before releasing it: equivalent on Chez 10.4.1, where
  `mutex-acquire` and the interrupt calls cost no engine ticks (#43's
  measurement for the send fence, which has the same shape).

## Gates

All on `2a7e456`, on `bfd2bbe`; the commit that carries this log differs from it only in this log:

- **macOS arm64:** `make test`, 25 suites; `make test-threading`;
  `make check-purity`; `make check-help`; `make check-memory-gate` (every
  planted defect caught); `make test-memory` (ASan: the new suite ran all
  16 rows, races included).
- **Linux aarch64, Ubuntu 24.04, gcc 13.3, apt libuv 1.48** (CI's
  pkg-config leg, the `chez-libuv-noble-scratch` image, `CHEZ=scheme`):
  `check-pins`, `deps`, `build`, `make test`, 25 suites. The shim's atomic
  counters compile under `-std=c99 -Werror -Wconversion`; the new suite ran
  all 16 rows, the source rules 32.
- **`make test-memory-docker`** (Debian bookworm, Valgrind 3.19, vendored
  libuv 1.52.1), from a `--no-hardlinks` clone: every planted defect
  caught; every suite 0 errors and 0 bytes definitely lost; the new suite
  ran its 6 rows that need no race; the 76 forked-child reports are the
  known non-gating artifacts, as before.

An ad-hoc noble run without `CHEZ=scheme` failed every suite with
"failed to run command 'chez'": the image's Chez is installed as
`scheme`, which CI's "Resolve the Chez binary" step finds and exports. The rerun
above passes it.

### After the rebase onto `30a7bd1` (#75)

#75 made `uv-process-kill!` and `uv-process-pid` one step each and added
`tests/test-process-steps.sps`, whose spawns go through the locked
`registry-add!`. The rebased tree is the one `git merge-tree` gives for main
and `e3d04f1`. `make test` on macOS passed 26 suites at load 68: the new
suite 16 rows, #75's 12. Rule 6 also passes with #73's `src/`
(`fix/spawn-list-reads`, `519924b`) merged in.
