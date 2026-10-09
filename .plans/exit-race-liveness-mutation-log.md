# #91: test-loop-claim's exit race waits on the other thread — mutation log

Branch `test/exit-race-progress`, on main 0fa1965, 2026-10-08.

## The failure

`precondition: the other thread ran some of those loops`, `actual: (0 stopped
0)`, on correct builds. The exit race made a fixed 2,000 bodies, each leaving
`call-with-uv-loop` from inside a timer callback, while another thread ran
every loop it found open and unclaimed. Measured with main's suite:

| Where | Runs | Failed |
|---|---|---|
| Ubuntu 24.04 mirror (arm64 Docker, libuv 1.48.0) | 8 | 6 (5 of 5 idle) |
| Ubuntu 26.04 mirror (libuv 1.51.0, vendored 1.52.1) | 7 | 2 (both under load) |
| CI, ubuntu-26.04 x64 (PR #92's first run) | 1 | 1 |
| macOS (`make test`) | many | 0 |

## What the probe found on the way

`probe-rate.sps`, the fixture with the body count as an argument, run on
one thread:

| Where | Bodies | The other thread got in |
|---|---|---|
| macOS | 20,000 (3 runs) | 16, 13, 91 times, in bursts: e.g. bodies 2225–2226, 5459–5462 |
| 24.04 mirror | 1,000 / 2,000 / 4,000 / 8,000 / 12,000 / 16,000 | 0 / 0 / 1 / 0 / 1 / 2 |
| 24.04 and 26.04 mirrors | 20,000 | **Segmentation fault**, every run |

The segfault is not the race. With the other thread removed:

| Where | Escapes | Result |
|---|---|---|
| Linux main thread, 8 MB | 20,000 / 40,000 | SIGSEGV / SIGSEGV |
| Linux main thread, `ulimit -s 65536` | 40,000 | passes |
| Linux `fork-thread` thread | 2,000 / 8,000 / 16,000 / 24,000 | passes ×3 / SIGSEGV |
| macOS main thread, 8 MB | 20,000 / 40,000 | passes / SIGSEGV (rc 139) |
| macOS main thread, `ulimit -s 65520` | 40,000 | passes |
| macOS `fork-thread` thread | 500 / 1,000 / 2,000 | passes / passes / **hangs** (300 s timeout) |

Every escape strands the C frames of the `uv_run` it left on its thread's
stack for as long as the thread lives. `sample` of the hung macOS process
showed the worker blocked in `S_condition_wait` under 170+ nested `uv_run`
frames, and the main thread waiting on it. docs/api.md ("A callback ends
only by returning") and AGENTS.md (C and the FFI) now say so.

## The fix

- The bodies run in batches of `exit-race-batch` (250), each batch on a
  thread of its own, so no thread strands more than 250 escapes: a quarter
  of the smallest measured capacity, a macOS `fork-thread` thread's.
- Batches go on until the other thread has got in `exit-race-hits` (100)
  times and at least 2,000 bodies are made, bounded by `race-time-cap`
  (10 s), never by a count of the body thread's own (#74). The precondition
  still asks for one run. A batch that does not end within the cap stops
  the race with `(batch-never-ended)`.
- The race answers `(stranded stopped ran bodies)`, and an informational
  line prints the last two.

## Rows

Correct build, the final suite, alternating images:

| Where | Runs | Passed | The other thread's runs / bodies | Time |
|---|---|---|---|---|
| 24.04 mirror | 5 | 5 | 107–214 / 2,750–38,250 | 1–2 s |
| 26.04 mirror | 5 | 5 | 108–253 / 11,250–66,250 | 1–2 s |
| macOS | 5 (+ `make test`) | 5 (+ ALL SUITES PASSED) | 100–156 / 19,250–149,750 | 1–4 s |

Mutations, in scratch copies outside the repo, exact single-match edits:

| Row | Mutation | Where | Result |
|---|---|---|---|
| N3 | the exit re-claims after any refusal: `(when (and failure (not (claim-refusal? failure)) (loop-open? loop))` → `(when (and failure (loop-open? loop))` (#83's N3) | macOS ×5 | FAIL `bodies left from a timer callback … no loop is left claimed …` in **5 of 5**, `(6 stopped)` `(14 stopped)` `(10 stopped)` `(1 stopped)` `(7 stopped)` |
| N3 | same | 24.04 ×10 | caught in **1 of 10**, `(1 stopped)` |
| N3, main's suite | same, with main's exit race | 24.04 ×3 | never caught: the precondition fails `(0 stopped 0)` and the main row passes, having raced nothing |
| kept out | test side: the other thread raises instead of calling `uv-run` | 24.04 | FAIL `precondition: …` by name, `(0 stopped 0 1254500)`, in 12 s |
| kept out | same | macOS | FAIL by name, `(0 stopped 0 494500)`, in 11 s, no hang |
| N9 (re-made) | the teardown holds its claim across its steps: start-teardown! keeps it, the drain runs unclaimed, the close takes a claim this thread holds; the exit race forced to run though earlier races were stuck | 24.04 | both exit-race rows FAIL by name, `(0 never-stopped)` and `(0 never-stopped 0 0 batch-never-ended)`, in 40 s. Broader than #83's N9: 19 rows failed |
| one batch | kept out, and `exit-race-batch` 1,000,000 (no batching) | 24.04 | **Segmentation fault**: the suite died with no row named. Batching is what turns this into a named failure |

N3 at other targets, 24.04: 20 runs caught it in 0 of 3 races, 100 in 2 of
3, 500 in 1 of 5. Whether a stranded loop appears depends on the other
thread's run ending between the refusal and the re-claim, so more runs did
not buy proportionally more: 100 is the target, at about 1 s.

**Weakly held, and why:** N3 on Linux, 1 in 10 at the target. Catching it
reliably would need a deterministic interleaving (two engine expiries inside
one exit), which this change does not attempt. On macOS it is caught 5 of 5.

**Since #96:** test-loop-claim's engine split of the exit catches N3 in
every run (`.plans/exit-reclaim-split-mutation-log.md`).
