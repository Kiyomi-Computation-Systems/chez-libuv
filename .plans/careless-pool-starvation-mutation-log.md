# Careless pool under a starved loop thread: mutation log

Evidence for the change to `tests/test-threading-stress.sps`'s careless pool
(#33's stress block). A worker there no longer stops at a fixed send cap. It
sends for as long as the loop thread takes to close, and what ends it on a
build that never refuses is the documented contract instead: a send made once
the close has begun is refused. The suite also gains the failing-row hook the
other threaded suites have, so a failing row prints its actual value.

## The incident

On 2026-10-06, `make test-threading` on main at 32ea8d7 failed once, at a
load average of 97 (5-minute average 53) while about ten other sessions ran
`make test`, Docker Valgrind gates and mutation harnesses:

```
FAIL every careless sender is refused with &uv-handle-closed, and nothing else raises
# of expected passes      11
# of unexpected failures  1
```

SRFI-64's simple runner printed no actual value, so the failing round's
outcomes were lost. The suite then passed 14 runs at loads of 140–170.

In each of 30 rounds, four workers call `uv-async-send!` without a lock of
their own until refused, and the loop thread closes the async at its 50th
wake. A worker's outcome was `'refused`, `(raised <describe>)`, or
`(never-refused 1000000)` once it had made the cap's 1,000,000 sends. Two
explanations were open: (a) load starves the loop thread while a worker
reaches the cap, a test defect; (b) a race in the send fence, a library
defect.

Platform: macOS arm64 (Apple M1, 4 performance and 4 efficiency cores),
Darwin 25.6.0, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1 via pkg-config, the
dev build, main at 5ac8469. The stress suite runs on no other gate: it is
outside `MEMORY_TESTS` and CI.

---

## Method

- **Probe.** A scratch copy of the suite with one line inserted before the
  row, printing every round whose result is not
  `(returned every-worker-refused)`:

  ```scheme
  (for-each (lambda (r) (unless (equal? r '(returned every-worker-refused)) (display "  [probe] round: ") (write r) (newline))) round-results)
  ```

  Each run is `CHEZSCHEMELIBDIRS=<worktree>/src:<worktree>/tests:<worktree>/build/scheme-libs chez --program <copy>`,
  under `timeout 300`, with the 1/5/15-minute load average recorded beside
  it. A forced cap of 10 made the probe print its rounds, so it is live.
- **Measure.** `measure.sps`, a scratch copy of the careless block alone,
  records each worker's sends before its outcome, the wake that closed, and
  each round's wall time, 30 rounds a run.
- **Load.** `yes > /dev/null` processes at normal priority, 96 at a time, in
  bounded windows (05:59–06:40 local, 2026-10-07), plus other sessions' work.
  CPU load only, no loopback traffic. Other sessions were told of the window
  beforehand.
- **Batches** run from frozen scratch copies of the suite, so an edit to the
  worktree mid-batch changes nothing. Up to four loops ran at once.
- **Mutations** run on scratch copies of `src/` and `tests/`. Each is an exact
  text replacement that aborts unless its target occurs exactly once, and the
  edit is checked present afterwards. The repo tree was never mutated.

---

## Capture: the failure is a starved loop thread

The unmodified suite, probe copy:

| load (1-minute) | runs | runs failed | the failing round |
|---|---|---|---|
| 3.7–4.1, nothing added | 30 | 0 | — |
| 40–214 (median 160) | 170 | **3** | `(returned (refused refused refused (never-refused 1000000)))`, every time |

The three failures came at loads of 140, 171 and 170. Each failed run had
exactly one failing round, with one worker at the cap, and the incident's
tally (11 passes, 1 failure). In the other 5,097 loaded rounds and the 900
idle ones, every worker ended `'refused`. No round produced a `(raised …)`
outcome, which is what a fence race would show. So the outcome is (a).

## The margin, measured

`measure.sps`, the busiest worker's sends before it was refused:

| load (1-minute) | runs × rounds | busiest worker per run | median of the rounds' busiest | slowest round |
|---|---|---|---|---|
| 3.7–4.1 | 30 × 30 | 1,230 – 9,049 | 655 – 1,061 | 1 – 3 ms |
| 76–160 | 14 × 30 | 387,111 – **774,427** | 540 – 219,466 | 286 – 572 ms |

Idle, the cap stood about 100 times above the busiest worker. Under load a
worker reached 77% of it before the 50th wake. The cap measured how far the
workers got while the loop thread waited for a CPU, not anything about the
fence.

## The change

- `close!` begins the close with `uv-close!`, then sets `close-begun`. The
  loop thread's close in `on-wake` and the fallback close after `uv-run` both
  use it.
- A worker reads `close-begun` before each send. If it was set and the send
  returned, the worker ends `(sent-after-close n)`. docs/api.md: "a send …
  either completes before a close begins or raises `&uv-handle-closed`".
- The cap is gone. Before the close a worker sends without bound; after the
  close begins it makes at most one more send. So a round always ends once
  the loop thread closes, however long it is starved.
- The failing-row hook, byte-identical to `tests/test-async-fence.sps`'s.

## RED, then GREEN: a starved loop thread on demand

A scratch edit stalls the first round's loop thread once: a 2-second `sleep`
in `on-wake` at its first wake. That is a starved loop thread made
deterministic.

| suite | runs (load) | result |
|---|---|---|
| main's, stalled | 2 (~140), 1 (~13) | the refusal row fails, 11 pass and 1 fails, every run. The probe: `(returned ((never-refused 1000000) (never-refused 1000000) (never-refused 1000000) (never-refused 1000000)))` |
| this change's, stalled | 2 (~165), 1 (~13) | 12 pass, every run. A counting copy showed the busiest worker made 1,890,494 sends in the stalled round and was then refused |

## The whole suite, loaded and idle

| suite | runs | load (1-minute) | careless row failed | other rows failed |
|---|---|---|---|---|
| main's | 170 | 40–214, median 160 | 3 | 0 |
| this change's | 279 | 165–227, median 192 | **0** | 2, see "Out of scope" |
| main's | 30 | 3.7–4.1 | 0 | 0 |
| this change's | 30 | ~9 | 0 | 0 |

No worker of this change's 309 runs ended `(sent-after-close n)`. The check
is exercised on a correct build: a counting copy at load ~6.5 found 5–18 of
each run's 120 workers refused on a send they began after seeing
`close-begun` (5 runs), the rest on a send begun before it.

---

## Mutations

Every mutant runs the whole suite. "Rounds" counts the careless refusal
row's 30 rounds, read from the actual value the hook now prints.

### The send path (`src/libuv/async.sls`)

| | mutation | result |
|---|---|---|
| M1 | `uv-async-send!` unfenced: main's shape before #43 (e79996c), on today's handles | load ~170: the refusal row fails in **6 of 6** runs. Load ~10: 7 of 30, then 24 of 30, then 13 of 20, so **44 of 80**. In the 37 failing runs whose rounds were tallied (the last two batches), the failing rounds hold only `invalid memory reference` and `&uv-invalid-argument … null-handle-pointer` raises, the race itself, and never a cap or a `sent-after-close` |
| M1 on main's suite | M1 on the old suite plus the probe, alternated run by run with the 13 of 20 batch above | 10 of 20. In one failing run, 17 workers also reached the cap, beside 5 race raises |
| M6 | the refusal raised as `&uv-invalid-argument` | 30 of 30 rounds, all 120 outcomes that raise |
| SR | a refused send returns 0, silently | 30 of 30 rounds, all 120 outcomes `(sent-after-close n)`, n 354–27,379. On main's suite all 120 end `(never-refused 1000000)`: it caught this only through its cap |

M1 is the mutation #33's review measured this row against. With the cap
gone, the row still catches it through the property it asserts: a raise
other than the refusal. M6 shows it always catches a wrong refusal, and SR a
send that returns once the close has begun.

### The round's own decisions (`tests/test-threading-stress.sps`)

| | mutation | result |
|---|---|---|
| T1 | the worker reads `close-begun` after its send, not before | false failures on a correct build: 12 of 30 rounds `(sent-after-close n)`, load ~214 |
| T1w | T1 with 100 µs between the send and the read | 28 of 30 rounds |
| T2 | `close!` sets `close-begun` before `uv-close!` | false failures: 22 of 30 rounds |
| T2w | T2 with 1 ms between the flag and the close | 30 of 30 rounds |
| T3 | `close!` never sets `close-begun` | 12 pass on a correct build. With SR: **hangs**, killed at 90 s (SR alone fails by name in 13 s) |
| T5 | the worker ignores `close-begun` | 12 pass on a correct build. With SR: **hangs**, killed at 90 s |
| T4 | the fallback close after `uv-run` does not set `close-begun` | 12 pass on a correct build. With SR and F5 below: **hangs**, killed at 90 s (SR and F5 alone fail both rows by name in 10 s) |

T1 and T2 show that the order of the read and of the flag matters: either
reversal fails the row on correct code. T3, T5 and T4 show that the flag is
what ends a worker on a build that never refuses. Without it, the round
waits for good.

### Injected failures

| | injection | result |
|---|---|---|
| F5 | the careless `on-wake` raises at every wake | the precondition row fails 30 of 30 (`&uv-callback-error: injected-on-wake-failure`), 11 pass, no hang |
| F6 | every careless worker raises after 10 sends | the refusal row: 30 of 30 rounds, 96 `(raised "injected-worker-failure")`; 11 pass, no hang (8 s) |
| F6b | F6 without the close on a worker's failure | **hangs**, killed at 90 s: that close is still load-bearing |

These repeat F5, F6 and F6b of `.plans/async-send-fence-mutation-log.md`
with the same results.

### Explored, not used

| | mutation | result |
|---|---|---|
| NC | an async's close leaves it `'open` until its close callback | hangs both suites, main's and this one, killed at 300 s. A sample showed the main thread and three workers blocked in `S_mutex_acquire`, with the process idle. That fits a send faulting inside the fence's interrupt-free step and leaving the fence held: the trade-off in the send-fence log's "The widened window, again". Not diagnosed further; it breaks the close's bookkeeping, not this round |

### The hook

Every failing run above printed its row's actual value. Before this change
the suite printed only titles, which is why the incident's outcome was lost.

## Uncovered, and why

- **M1's catch depends on load**, as before: 44 of 80 runs near load 10,
  every run near 170. The default gate's `tests/test-async-fence.sps` owns
  the fence; this block shows four senders and a closer under contention.
- **That a send begun after the flag is refused rests on the fence's lock
  order.** `close!` sets the flag after `uv-close!` has released the fence,
  and a sender reads it before taking the fence for its send. T1 and T2
  break that order from the test's side and fail by name. On the correct
  build no worker ended `(sent-after-close n)` in 309 runs.

## Out of scope: two more rows that flake near load 200

Neither appeared in main's 170 loaded runs (median load 160). Both appeared
in this change's 279 runs at loads of 165–227 (median 192), in rows this
change does not touch.

1. **The discipline pool's refusal row**, run 72 of one loop, load 200:
   `(refused (never-refused 1000000) refused refused)` in one round. The same
   mechanism: the pool's 1,000,000-post cap races a starved loop thread. Its
   comment says "the busiest measured: ~20000". Measured at loads of
   145–160, its busiest worker posted 158,987–304,839 items a run. Removing
   that cap is not free: each post conses an item onto the shared queue, so
   an uncapped worker under a starved loop thread grows the queue without
   bound.
2. **"no collection completes while copy-out is inside its foreign call"**,
   run 86 of another loop, load 205: `(never-tried 0)`. The helper thread
   never tried to collect inside any of the three 64 MiB copy-out intervals,
   so the row's precondition failed, not its property.

Both are left for their own change.

## Gates

The change was written on 5ac8469 and moved onto bfd2bbe (#72) by a clean
cherry-pick. On that commit, macOS arm64, load under 3:

- `make test`: ALL SUITES PASSED, 24 suites.
- `make test-threading`: STRESS SUITES PASSED, 12 rows, in 3 of 3 runs.
- `make check-purity` and `make check-help`: exit 0.

The same gates passed on 5ac8469. The stress suite runs on no other gate:
not CI, not the memory gate.
